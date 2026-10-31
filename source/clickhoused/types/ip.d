/++
`IPv4` and `IPv6` columns and value types.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.ip;

import std.variant : Variant;

import clickhoused.exception : ClientException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column : Column, FixedColumn, makeVariant, readChunkRows;

/++
An IPv4 address. `value` is the address as a number: `1.2.3.4` is
`0x01020304`, the same as `std.socket.InternetAddress.addr`.
+/
struct IPv4
{
    /// The address as a number.
    uint value;

    /++
    Parses dotted-decimal text such as `"192.168.0.1"`.

    Throws: `ClientException` if the text is not an IPv4 address.
    +/
    static IPv4 fromString(scope const(char)[] text) @safe pure
    {
        const result = parseIPv4(text);
        if (result < 0)
            throw new ClientException("Cannot parse '" ~ text.idup ~ "' as an IPv4 address");
        return IPv4(cast(uint) result);
    }

    /// Dotted-decimal text, e.g. `"192.168.0.1"`.
    string toString() const @safe pure nothrow
    {
        char[15] buffer;
        return formatIPv4(value, buffer).idup;
    }
}

/++
An IPv6 address: 16 bytes in network order, the same as
`std.socket.Internet6Address.addr`.
+/
struct IPv6
{
    /// The address bytes, most significant first.
    ubyte[16] bytes;

    /++
    Parses IPv6 text such as `"2001:db8::7"` or `"::ffff:1.2.3.4"`. IPv4 text
    gives the IPv4-mapped address (`"1.2.3.4"` is `::ffff:1.2.3.4`), as in
    ClickHouse.

    Throws: `ClientException` if the text is not an IP address.
    +/
    static IPv6 fromString(scope const(char)[] text) @safe pure
    {
        const v4 = parseIPv4(text);
        if (v4 >= 0)
            return mapped(IPv4(cast(uint) v4));
        IPv6 result;
        if (!parseIPv6(text, result.bytes))
            throw new ClientException("Cannot parse '" ~ text.idup ~ "' as an IPv6 address");
        return result;
    }

    /// The IPv4-mapped address of `address`: `::ffff:a.b.c.d`.
    static IPv6 mapped(IPv4 address) @safe pure nothrow @nogc
    {
        IPv6 result;
        result.bytes[10] = 0xff;
        result.bytes[11] = 0xff;
        result.bytes[12] = cast(ubyte)(address.value >> 24);
        result.bytes[13] = cast(ubyte)(address.value >> 16);
        result.bytes[14] = cast(ubyte)(address.value >> 8);
        result.bytes[15] = cast(ubyte) address.value;
        return result;
    }

    /++
    The address as ClickHouse prints it: lowercase hex, the longest run of
    zero groups (two or more) as `::`, and IPv4-mapped and -compatible
    addresses with a dotted tail (`::ffff:1.2.3.4`, `::1.2.3.4`).
    +/
    string toString() const @safe pure nothrow
    {
        ushort[8] words;
        foreach (i; 0 .. 8)
            words[i] = cast(ushort)(bytes[2 * i] << 8 | bytes[2 * i + 1]);
        // The longest run of zero words; the first one wins a tie
        size_t bestStart, bestLength, start, length;
        foreach (i, w; words)
        {
            if (w != 0)
            {
                length = 0;
                continue;
            }
            if (length++ == 0)
                start = i;
            if (length > bestLength)
            {
                bestStart = start;
                bestLength = length;
            }
        }
        if (bestLength < 2)
            bestLength = 0;

        string s;
        foreach (i; 0 .. 8)
        {
            if (bestLength && i >= bestStart && i < bestStart + bestLength)
            {
                if (i == bestStart)
                    s ~= ':';
                continue;
            }
            if (i != 0)
                s ~= ':';
            // An IPv4 address embedded after 96 zero bits, or after ::ffff:
            if (i == 6 && bestLength && bestStart == 0 && (bestLength == 6 || (bestLength == 5
                    && words[5] == 0xffff)))
            {
                char[15] buffer;
                return s ~ formatIPv4(bytes[12] << 24 | bytes[13] << 16 | bytes[14] << 8 | bytes[15], buffer);
            }
            s ~= hex(words[i]);
        }
        if (bestLength && bestStart + bestLength == 8)
            s ~= ':';
        return s;
    }
}

///
@safe unittest
{
    assert(IPv4.fromString("1.2.3.4").value == 0x0102_0304);
    assert(IPv6.fromString("2001:0db8:0000:0000:0001:0000:0000:0001").toString() == "2001:db8::1:0:0:1");
    assert(IPv6.fromString("1.2.3.4").toString() == "::ffff:1.2.3.4"); // IPv4-mapped
}

/// Parses dotted-decimal IPv4 text; returns the address, or -1 if the text is not one.
private long parseIPv4(scope const(char)[] text) @safe pure nothrow @nogc
{
    uint value, part, digits, dots;
    foreach (c; text)
    {
        if (c == '.')
        {
            if (digits == 0 || ++dots > 3)
                return -1;
            value = value << 8 | part;
            part = 0;
            digits = 0;
        }
        else if (c >= '0' && c <= '9' && digits < 3)
        {
            part = part * 10 + (c - '0');
            digits++;
            if (part > 255)
                return -1;
        }
        else
            return -1;
    }
    if (dots != 3 || digits == 0)
        return -1;
    return value << 8 | part;
}

private bool parseIPv6(scope const(char)[] text, ref ubyte[16] bytes) @safe pure nothrow @nogc
{
    ushort[8] words;
    size_t count; // words parsed
    ptrdiff_t gap = -1; // position of "::"
    size_t pos;
    if (text.length >= 2 && text[0] == ':' && text[1] == ':')
    {
        gap = 0;
        pos = 2;
    }
    else if (text.length && text[0] == ':')
        return false;
    while (pos < text.length)
    {
        // A dotted IPv4 tail takes the last two words
        size_t end = pos;
        while (end < text.length && text[end] != ':')
            end++;
        const v4 = end == text.length ? parseIPv4(text[pos .. end]) : -1;
        if (v4 >= 0)
        {
            if (count > 6)
                return false;
            words[count++] = cast(ushort)(v4 >> 16);
            words[count++] = cast(ushort) v4;
            pos = end;
            break;
        }
        if (end == pos || end - pos > 4 || count == 8)
            return false;
        uint w;
        foreach (c; text[pos .. end])
        {
            const d = hexDigit(c);
            if (d < 0)
                return false;
            w = w << 4 | d;
        }
        words[count++] = cast(ushort) w;
        pos = end;
        if (pos == text.length)
            break;
        pos++; // ':'
        if (pos < text.length && text[pos] == ':')
        {
            if (gap >= 0)
                return false; // a second "::"
            gap = count;
            pos++;
        }
        else if (pos == text.length)
            return false; // a trailing single ':'
    }
    if (gap < 0 ? count != 8 : count > 7)
        return false;
    ushort[8] full;
    if (gap < 0)
        full = words;
    else
    {
        full[0 .. gap] = words[0 .. gap];
        const tail = count - gap;
        full[8 - tail .. 8] = words[gap .. count];
    }
    foreach (i, w; full)
    {
        bytes[2 * i] = cast(ubyte)(w >> 8);
        bytes[2 * i + 1] = cast(ubyte) w;
    }
    return true;
}

/// The value of a hex digit, or -1.
private int hexDigit(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

private const(char)[] formatIPv4(uint value, return ref char[15] buffer) @safe pure nothrow @nogc
{
    static immutable uint[4] shifts = [24, 16, 8, 0];
    size_t pos;
    foreach (shift; shifts)
    {
        const part = (value >> shift) & 0xff;
        if (shift != 24)
            buffer[pos++] = '.';
        if (part >= 100)
            buffer[pos++] = cast(char)('0' + part / 100);
        if (part >= 10)
            buffer[pos++] = cast(char)('0' + part / 10 % 10);
        buffer[pos++] = cast(char)('0' + part % 10);
    }
    return buffer[0 .. pos];
}

private string hex(ushort w) @safe pure nothrow
{
    static immutable digits = "0123456789abcdef";
    char[4] buffer;
    size_t pos = 4;
    do
    {
        buffer[--pos] = digits[w & 0xf];
        w >>= 4;
    }
    while (w);
    return buffer[pos .. $].idup;
}

@safe unittest
{
    import std.exception : assertThrown;

    // As ClickHouse prints them (checked on 23.8 and 26.11)
    foreach (pair; [
            ["::1", "::1"], ["2001:db8::7", "2001:db8::7"], ["::", "::"],
            ["fe80::1:0:0:1", "fe80::1:0:0:1"],
            ["::ffff:0:0", "::ffff:0.0.0.0"], ["1:2:3:4:5:6:7:8", "1:2:3:4:5:6:7:8"],
            ["::1.2.3.4", "::1.2.3.4"],
            ["1::", "1::"], ["1:0:0:2:0:0:0:3", "1:0:0:2::3"], [
                "1:0:2:3:4:5:6:7", "1:0:2:3:4:5:6:7"
            ],
            ["ABCD:EF01::", "abcd:ef01::"], ["::ffff:10.0.0.1", "::ffff:10.0.0.1"],
        ])
        assert(IPv6.fromString(pair[0]).toString() == pair[1], pair[0]);
    foreach (bad; [
        "", ":", ":::", "1:::2", "1::2::3", "12345::", "1:2:3:4:5:6:7:8:9", "1:2:3:4:5:6:7", "g::",
        "1:", ":1", "::1.2.3", "::1.2.3.4:5"
    ])
        assertThrown!ClientException(IPv6.fromString(bad), bad);

    assert(IPv4(0).toString() == "0.0.0.0" && IPv4(uint.max).toString() == "255.255.255.255");
    assert(IPv4.fromString("10.200.3.40").toString() == "10.200.3.40");
    foreach (bad; [
        "", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1..2.3", "1.2.3.4 ", "a.b.c.d", "1234.1.1.1"
    ])
        assertThrown!ClientException(IPv4.fromString(bad), bad);
}

/++
`IPv4` column: the addresses as numbers, as on the wire (`1.2.3.4` is
`0x01020304`, stored little-endian).
+/
final class IPv4Column : FixedColumn!uint
{
    /// Creates an empty column.
    this(string name, string typeName = "IPv4") @safe pure nothrow
    {
        super(name, typeName);
    }

    /// The address in `row`.
    IPv4 opIndex(size_t row) const @safe pure nothrow @nogc
    {
        return IPv4(data[row]);
    }

    override string getString(size_t row) const @safe
    {
        return this[row].toString();
    }

    /// Quoted inside arrays.
    override protected @property bool quotedInText() const @safe pure nothrow
    {
        return true;
    }

    /// The address as a number.
    override ulong getUlong(size_t row) const @safe
    {
        return data[row];
    }

    /// ditto
    override long getLong(size_t row) const @safe
    {
        return data[row];
    }

    /// The four address bytes, most significant first.
    override const(ubyte)[] getBytes(size_t row) const @safe
    {
        const v = data[row];
        return [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];
    }

    /// A `Variant` holding an `IPv4`.
    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(this[row]);
    }

    override void appendDefault() @safe
    {
        data ~= 0;
    }

    /// Appends an address.
    void appendIPv4(IPv4 address) @safe
    {
        data ~= address.value;
    }

    /// The address as a number.
    override void appendUlong(ulong value) @safe
    {
        if (value > uint.max)
            throw appendError("ulong", value);
        data ~= cast(uint) value;
    }

    /// ditto
    override void appendLong(long value) @safe
    {
        if (value < 0 || value > uint.max)
            throw appendError("long", value);
        data ~= cast(uint) value;
    }

    /// Four address bytes, most significant first.
    override void appendBytes(const(ubyte)[] value) @safe
    {
        if (value.length != 4)
            throw appendError("bytes", value.length);
        data ~= value[0] << 24 | value[1] << 16 | value[2] << 8 | value[3];
    }

    /// Parses dotted-decimal text.
    override void appendString(string value) @safe
    {
        try
            data ~= IPv4.fromString(value).value;
        catch (ClientException)
            throw appendError("string", value);
    }
}

/// `IPv6` column: 16 bytes per address in network order, as on the wire.
final class IPv6Column : Column
{
    /// Column values.
    IPv6[] data;

    /// Creates an empty column.
    this(string name, string typeName = "IPv6") @safe pure nothrow
    {
        super(name, typeName);
    }

    override @property size_t length() const @safe pure nothrow
    {
        return data.length;
    }

    override void readData(BufferedReader reader, size_t rows) @safe
    {
        data = null;
        while (data.length < rows)
        {
            const start = data.length;
            const count = rows - start < readChunkRows ? rows - start : readChunkRows;
            data.length = start + count;
            reader.readExact((() @trusted => cast(ubyte[]) data[start .. $])()); // 16 bytes each, as on the wire
        }
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        writer.writeBytes((() @trusted => cast(const(ubyte)[]) data)()); // 16 bytes each, as on the wire
    }

    /// The address in `row`.
    IPv6 opIndex(size_t row) const @safe pure nothrow @nogc
    {
        return data[row];
    }

    override string getString(size_t row) const @safe
    {
        return data[row].toString();
    }

    /// Quoted inside arrays.
    override protected @property bool quotedInText() const @safe pure nothrow
    {
        return true;
    }

    /// The 16 address bytes.
    override const(ubyte)[] getBytes(size_t row) const @safe
    {
        return data[row].bytes[];
    }

    /// A `Variant` holding an `IPv6`.
    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(data[row]);
    }

    override void truncate(size_t length) @safe
    {
        if (length < data.length)
            data.length = length;
    }

    /// Appends `::`.
    override void appendDefault() @safe
    {
        data ~= IPv6.init;
    }

    /// Appends an address.
    void appendIPv6(IPv6 address) @safe
    {
        data ~= address;
    }

    /// 16 address bytes.
    override void appendBytes(const(ubyte)[] value) @safe
    {
        if (value.length != 16)
            throw appendError("bytes", value.length);
        IPv6 address;
        address.bytes[] = value[];
        data ~= address;
    }

    /// Parses IPv6 text; IPv4 text gives the IPv4-mapped address.
    override void appendString(string value) @safe
    {
        try
            data ~= IPv6.fromString(value);
        catch (ClientException)
            throw appendError("string", value);
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        data ~= sameKind!IPv6Column(source).data[row];
    }
}

@safe unittest
{
    import std.exception : assertThrown;

    auto v4 = new IPv4Column("a");
    v4.appendString("1.2.3.4");
    v4.appendUlong(0x7f00_0001);
    v4.appendBytes([10, 0, 0, 1]);
    assert(v4.getString(0) == "1.2.3.4" && v4.getString(1) == "127.0.0.1" && v4.getUlong(2) == 0x0a00_0001);
    assert(v4.getQuotedString(0) == "'1.2.3.4'" && v4.getBytes(0) == [1, 2, 3, 4]);
    assertThrown!ClientException(v4.appendString("::1"));
    assertThrown!ClientException(v4.appendLong(-1));
    assert(v4.length == 3);

    auto v6 = new IPv6Column("b");
    v6.appendString("2001:db8::7");
    v6.appendString("1.2.3.4");
    v6.appendDefault();
    assert(v6.getString(0) == "2001:db8::7" && v6.getString(1) == "::ffff:1.2.3.4" && v6.getString(2) == "::");
    assertThrown!ClientException(v6.appendBytes([1, 2]));
    assertThrown!ClientException(v6.appendString("x"));
    assert(v6.length == 3);
}

// Golden bytes from `clickhouse client -q "SELECT toIPv4('1.2.3.4'), toIPv6('2001:db8::7') FORMAT Native"`
@safe unittest
{
    import clickhoused.io.mock : MockTransport;

    auto t = new MockTransport;
    t.feed([4, 3, 2, 1, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7]);
    auto r = new BufferedReader(t);
    auto v4 = new IPv4Column("a");
    v4.readData(r, 1);
    auto v6 = new IPv6Column("b");
    v6.readData(r, 1);
    assert(v4.getString(0) == "1.2.3.4" && v6.getString(0) == "2001:db8::7" && t.remaining == 0);

    auto w = new MockTransport;
    auto writer = new BufferedWriter(w);
    v4.writeData(writer);
    v6.writeData(writer);
    writer.flush();
    assert(w.written == [4, 3, 2, 1, 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7]);
}
