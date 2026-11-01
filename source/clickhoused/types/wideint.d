/++
128- and 256-bit integers: the value types `Int128`, `UInt128`, `Int256`,
`UInt256`, and their columns.

The value types hold a number exactly as ClickHouse stores it and convert it
to and from decimal text, `long`/`ulong`, `double` and `std.bigint.BigInt`
(for arithmetic). With a D frontend 2.100 or newer, `Int128` also converts to
and from `std.int128.Int128`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.wideint;

import std.bigint : BigInt, toDecimalString;
import std.traits : isIntegral, isSigned;
import std.variant : Variant;

import clickhoused.exception : ClientException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column : appendFast, Column, makeVariant, readChunkRows;

/// Whether `std.int128` is available (D frontend 2.100 and newer).
enum bool haveStdInt128 = __traits(compiles, () { import std.int128 : Int128; });

/++
A signed or unsigned integer of `bits` bits (128 or 256), stored as on the
wire: little-endian 64-bit words, two's complement when signed.

It supports comparison and conversions, not arithmetic: convert to
`std.bigint.BigInt` (or `std.int128.Int128`) to compute.
+/
struct WideInt(uint bits, bool signed) if (bits == 128 || bits == 256)
{
    /// Number of 64-bit words.
    enum size_t wordCount = bits / 64;

    /// The value: `words[0]` holds the lowest 64 bits.
    ulong[wordCount] words;

    /// The smallest value.
    enum WideInt min = () {
        WideInt v;
        static if (signed)
            v.words[$ - 1] = 1UL << 63;
        return v;
    }();

    /// The largest value.
    enum WideInt max = () {
        WideInt v;
        v.words[] = ulong.max;
        static if (signed)
            v.words[$ - 1] = long.max;
        return v;
    }();

    /++
    Creates a value from a built-in integer.

    Throws: `ClientException` if `value` is negative and the type is unsigned.
    +/
    this(T)(T value) @safe pure if (isIntegral!T)
    {
        static if (isSigned!T)
        {
            static if (!signed)
                if (value < 0)
                    throw new ClientException("Negative value for an unsigned " ~ typeName ~ ": " ~ toText(value));
            words[0] = cast(ulong) cast(long) value;
            if (value < 0)
                words[1 .. $] = ulong.max;
        }
        else
            words[0] = value;
    }

    /// The ClickHouse type name, e.g. `"Int128"`.
    enum string typeName = (signed ? "Int" : "UInt") ~ (bits == 128 ? "128" : "256");

    /// Whether the value is below zero.
    @property bool isNegative() const @safe pure nothrow @nogc
    {
        static if (signed)
            return (words[$ - 1] >> 63) != 0;
        else
            return false;
    }

    /// Compares two values.
    int opCmp(const WideInt other) const @safe pure nothrow @nogc
    {
        if (isNegative != other.isNegative)
            return isNegative ? -1 : 1;
        // With equal signs, two's complement orders like the unsigned words
        foreach_reverse (i; 0 .. wordCount)
            if (words[i] != other.words[i])
                return words[i] < other.words[i] ? -1 : 1;
        return 0;
    }

    /// The value in decimal, e.g. `"-170141183460469231731687303715884105728"`.
    string toString() const @safe pure nothrow
    {
        uint[2 * wordCount] limbs = magnitude();
        char[bits / 3 + 2] buffer; // enough for every digit and the sign
        size_t pos = buffer.length;
        for (;;)
        {
            uint chunk = divideBy(limbs[], 1_000_000_000);
            const last = isZero(limbs);
            // Every chunk but the most significant one has exactly nine digits
            foreach (i; 0 .. 9)
            {
                if (last && chunk == 0 && i > 0)
                    break;
                buffer[--pos] = cast(char)('0' + chunk % 10);
                chunk /= 10;
            }
            if (last)
                break;
        }
        if (isNegative)
            buffer[--pos] = '-';
        return buffer[pos .. $].idup;
    }

    /++
    Parses decimal text: an optional sign followed by digits.

    Throws: `ClientException` if the text is not a number of this type.
    +/
    static WideInt fromString(scope const(char)[] text) @safe pure
    {
        ClientException error()
        {
            return new ClientException("Cannot parse '" ~ text.idup ~ "' as " ~ typeName);
        }

        bool negative;
        size_t pos;
        if (text.length && (text[0] == '-' || text[0] == '+'))
        {
            negative = text[0] == '-';
            pos = 1;
        }
        if (pos == text.length)
            throw error();
        uint[2 * wordCount + 1] limbs; // one extra limb catches overflow
        foreach (c; text[pos .. $])
        {
            if (c < '0' || c > '9')
                throw error();
            ulong carry = c - '0';
            foreach (ref limb; limbs)
            {
                const v = limb * 10UL + carry;
                limb = cast(uint) v;
                carry = v >> 32;
            }
            if (limbs[$ - 1] != 0)
                throw error();
        }
        WideInt result;
        foreach (i; 0 .. wordCount)
            result.words[i] = limbs[2 * i] | (cast(ulong) limbs[2 * i + 1] << 32);
        static if (signed)
        {
            // The magnitude may reach 2^(bits-1) only for the most negative value
            if ((result.words[$ - 1] >> 63) != 0 && !(negative && result == min))
                throw error();
        }
        else
        {
            if (negative && result != WideInt.init)
                throw error();
        }
        if (negative)
            result = result.negated();
        return result;
    }

    /++
    The value as a `long`.

    Throws: `ClientException` if it does not fit.
    +/
    long toLong() const @safe pure
    {
        // Fits if all higher words are the sign extension of the lowest one
        const extension = cast(long) words[0] < 0 ? ulong.max : 0;
        static if (!signed)
            if (extension != 0)
                throw rangeError("long");
        foreach (w; words[1 .. $])
            if (w != extension)
                throw rangeError("long");
        return cast(long) words[0];
    }

    /++
    The value as a `ulong`.

    Throws: `ClientException` if it does not fit.
    +/
    ulong toUlong() const @safe pure
    {
        foreach (w; words[1 .. $])
            if (w != 0)
                throw rangeError("ulong");
        return words[0];
    }

    /// The value as a `double` (rounded).
    double toDouble() const @safe pure nothrow @nogc
    {
        const negative = isNegative;
        const abs = negative ? negated() : this;
        double result = 0;
        foreach_reverse (w; abs.words)
            result = result * 18_446_744_073_709_551_616.0 + w; // 2^64
        return negative ? -result : result;
    }

    /// The value as a `std.bigint.BigInt`.
    BigInt toBigInt() const @safe
    {
        auto result = BigInt(0);
        foreach_reverse (w; words)
        {
            result <<= 64;
            result += w;
        }
        static if (signed)
            if (isNegative)
                result -= BigInt(1) << bits;
        return result;
    }

    /++
    Converts a `std.bigint.BigInt`.

    Throws: `ClientException` if it does not fit.
    +/
    static WideInt fromBigInt(const BigInt value) @safe
    {
        if (value < min.toBigInt() || value > max.toBigInt())
            throw new ClientException("Value out of range for " ~ typeName ~ ": " ~ value.toDecimalString());
        const unsignedValue = value < 0 ? value + (BigInt(1) << bits) : value;
        WideInt result;
        foreach (i; 0 .. wordCount)
            if (i < unsignedValue.ulongLength)
                result.words[i] = unsignedValue.getDigit(i);
        return result;
    }

    static if (haveStdInt128 && bits == 128 && signed)
    {
        import std.int128 : StdInt128 = Int128;

        /// The value as a `std.int128.Int128` (D frontend 2.100 and newer).
        StdInt128 toStdInt128() const @safe pure nothrow @nogc
        {
            return StdInt128(cast(long) words[1], cast(long) words[0]);
        }

        /// Converts a `std.int128.Int128` (D frontend 2.100 and newer).
        static WideInt fromStdInt128(const StdInt128 value) @safe pure nothrow @nogc
        {
            WideInt result;
            result.words[0] = value.data.lo;
            result.words[1] = value.data.hi;
            return result;
        }
    }

    /// Two's complement negation.
    private WideInt negated() const @safe pure nothrow @nogc
    {
        WideInt result;
        ulong carry = 1;
        foreach (i, w; words)
        {
            const inverted = ~w;
            result.words[i] = inverted + carry;
            carry = carry && result.words[i] == 0;
        }
        return result;
    }

    /// The absolute value as little-endian 32-bit limbs.
    private uint[2 * wordCount] magnitude() const @safe pure nothrow @nogc
    {
        const abs = isNegative ? negated() : this;
        uint[2 * wordCount] limbs;
        foreach (i, w; abs.words)
        {
            limbs[2 * i] = cast(uint) w;
            limbs[2 * i + 1] = cast(uint)(w >> 32);
        }
        return limbs;
    }

    private ClientException rangeError(string target) const @safe pure
    {
        return new ClientException("Value " ~ toString() ~ " of type " ~ typeName ~ " does not fit in " ~ target);
    }
}

/// `Int128`: signed 128-bit integer.
alias Int128 = WideInt!(128, true);
/// `UInt128`: unsigned 128-bit integer.
alias UInt128 = WideInt!(128, false);
/// `Int256`: signed 256-bit integer.
alias Int256 = WideInt!(256, true);
/// `UInt256`: unsigned 256-bit integer.
alias UInt256 = WideInt!(256, false);

/// Whether `T` is one of the `WideInt` types.
enum bool isWideInt(T) = is(T : WideInt!(bits, signed), uint bits, bool signed);

///
@safe unittest
{
    const big = Int128.fromString("-170141183460469231731687303715884105728");
    assert(big == Int128.min && big.isNegative);
    assert(big.toString() == "-170141183460469231731687303715884105728");
    assert(UInt256(42).toLong() == 42);
    assert((UInt256.max.toBigInt() + 1) == BigInt(1) << 256); // arithmetic through BigInt
}

/// Divides the little-endian limbs by `divisor` in place; returns the remainder.
private uint divideBy(scope uint[] limbs, uint divisor) @safe pure nothrow @nogc
{
    ulong remainder;
    foreach_reverse (ref limb; limbs)
    {
        const v = (remainder << 32) | limb;
        limb = cast(uint)(v / divisor);
        remainder = v % divisor;
    }
    return cast(uint) remainder;
}

private bool isZero(size_t n)(const ref uint[n] limbs) @safe pure nothrow @nogc
{
    foreach (l; limbs)
        if (l != 0)
            return false;
    return true;
}

private string toText(T)(T value) @safe pure
{
    import std.conv : to;

    return value.to!string;
}

@safe unittest
{
    import std.exception : assertThrown;

    // Limits, as ClickHouse prints them
    assert(Int128.max.toString() == "170141183460469231731687303715884105727");
    assert(UInt128.max.toString() == "340282366920938463463374607431768211455");
    assert(Int256.min.toString()
            == "-57896044618658097711785492504343953926634992332820282019728792003956564819968");
    assert(UInt256.max.toString()
            == "115792089237316195423570985008687907853269984665640564039457584007913129639935");
    assert(Int128(0).toString() == "0" && Int128(-1).toString() == "-1");
    assert(UInt128(1_000_000_000).toString() == "1000000000"); // a chunk boundary

    // Round trips through text and BigInt
    foreach (text; [
        "0", "-1", "1", "999999999", "1000000000", "-9223372036854775808", "18446744073709551616",
        "170141183460469231731687303715884105727", "-170141183460469231731687303715884105728"
    ])
    {
        const v = Int128.fromString(text);
        assert(v.toString() == text, text);
        assert(Int128.fromBigInt(v.toBigInt()) == v && v.toBigInt() == BigInt(text), text);
    }
    assert(Int256.fromString("+12").toString() == "12" && UInt128.fromString("-0") == UInt128(0));
    foreach (bad; [
        "", "-", "+", "1x", " 1", "170141183460469231731687303715884105728",
        "-170141183460469231731687303715884105729"
    ])
        assertThrown!ClientException(Int128.fromString(bad), bad);
    assertThrown!ClientException(UInt128.fromString("-1"));
    assertThrown!ClientException(UInt128.fromString("340282366920938463463374607431768211456"));
    assertThrown!ClientException(Int128.fromBigInt(BigInt(1) << 127));
    assertThrown!ClientException(UInt128(-1));

    // Comparison, conversion to built-in types
    assert(Int128(-5) < Int128(3) && Int128.min < Int128(-1) && Int128(2) > Int128(1));
    assert(UInt256(5) < UInt256.max);
    assert(Int128(-5).toLong() == -5 && Int128(long.min).toLong() == long.min);
    assertThrown!ClientException(Int128.fromString("9223372036854775808").toLong());
    assert(Int128.fromString("9223372036854775808").toUlong() == 9_223_372_036_854_775_808UL);
    assertThrown!ClientException(Int128(-1).toUlong());
    assertThrown!ClientException(UInt128.max.toUlong());
    assert(Int256(-3).toDouble() == -3.0 && UInt128.max.toDouble() == 2.0 ^^ 128);
}

static if (haveStdInt128)
{
    @safe unittest
    {
        import std.int128 : StdInt128 = Int128;

        const v = Int128.fromString("-123456789012345678901234567890");
        assert(Int128.fromStdInt128(v.toStdInt128()) == v);
        assert(Int128(-7).toStdInt128() == StdInt128(-7L));
    }
}

/// Column of 128- or 256-bit integers (`Int128`, `UInt128`, `Int256`, `UInt256`).
final class WideIntColumn(W) : Column if (isWideInt!W)
{
    /// Column values.
    W[] data;
    private W[] spare; // room for appends; see `appendFast`

    /// Appends `value`.
    void appendWide(W value) @safe pure nothrow
    {
        appendFast(data, spare, value);
    }

    /// Creates an empty column.
    this(string name, string typeName) @safe pure nothrow
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
            version (LittleEndian)
                reader.readExact((() @trusted => cast(ubyte[]) data[start .. $])()); // same layout as the wire
            else
            {
                foreach (ref v; data[start .. $])
                    foreach (ref w; v.words)
                        w = reader.readFixed!ulong();
            }
        }
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        version (LittleEndian)
            writer.writeBytes((() @trusted => cast(const(ubyte)[]) data)()); // same layout as the wire
        else
        {
            foreach (v; data)
                foreach (w; v.words)
                    writer.writeFixed(w);
        }
    }

    override long getLong(size_t row) const @safe
    {
        try
            return data[row].toLong();
        catch (ClientException)
            throw conversionError(row, "long");
    }

    override ulong getUlong(size_t row) const @safe
    {
        try
            return data[row].toUlong();
        catch (ClientException)
            throw conversionError(row, "ulong");
    }

    override double getDouble(size_t row) const @safe
    {
        return data[row].toDouble();
    }

    override bool getBool(size_t row) const @safe
    {
        return data[row] != W.init;
    }

    override string getString(size_t row) const @safe
    {
        return data[row].toString();
    }

    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(data[row]);
    }

    override void truncate(size_t length) @safe
    {
        if (length < data.length)
            data.length = length;
    }

    override void appendDefault() @safe
    {
        appendFast(data, spare, W.init);
    }

    override void appendLong(long value) @safe
    {
        try
            appendFast(data, spare, W(value));
        catch (ClientException)
            throw appendError("long", value);
    }

    override void appendUlong(ulong value) @safe
    {
        appendFast(data, spare, W(value));
    }

    /// Only whole numbers within the range of `long` or `ulong` are accepted.
    override void appendDouble(double value) @safe
    {
        import std.math : trunc;

        enum double lower = -(2.0 ^^ 63);
        enum double upper = 2.0 ^^ 64;
        if (value != trunc(value) || !(value >= lower && value < upper))
            throw appendError("double", value);
        if (value < 0)
            appendLong(cast(long) value);
        else
            appendUlong(cast(ulong) value);
    }

    override void appendBool(bool value) @safe
    {
        appendFast(data, spare, W(value ? 1 : 0));
    }

    /// Parses decimal text.
    override void appendString(string value) @safe
    {
        try
            appendFast(data, spare, W.fromString(value));
        catch (ClientException)
            throw appendError("string", value);
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        appendFast(data, spare, sameKind!WideIntColumn(source).data[row]);
    }
}

/// `Int128` column.
alias Int128Column = WideIntColumn!Int128;
/// `UInt128` column.
alias UInt128Column = WideIntColumn!UInt128;
/// `Int256` column.
alias Int256Column = WideIntColumn!Int256;
/// `UInt256` column.
alias UInt256Column = WideIntColumn!UInt256;

@safe unittest
{
    import std.exception : assertThrown;

    auto c = new Int128Column("i", "Int128");
    c.appendString("-170141183460469231731687303715884105728");
    c.appendLong(-5);
    c.appendUlong(ulong.max);
    c.appendDouble(-2.0);
    assert(c.getString(0) == "-170141183460469231731687303715884105728");
    assert(c.getLong(1) == -5 && c.getUlong(2) == ulong.max && c.getDouble(3) == -2.0);
    assertThrown!ClientException(c.getLong(0));
    assertThrown!ClientException(c.getUlong(1));
    assertThrown!ClientException(c.appendString("1e5"));
    assertThrown!ClientException(c.appendDouble(0.5));
    assert(c.length == 4); // failed appends add nothing
    assert((() @trusted => c.getVariant(1).get!Int128)() == Int128(-5)); // Variant.get is not @safe

    auto u = new UInt256Column("u", "UInt256");
    assertThrown!ClientException(u.appendLong(-1));
    u.appendDefault();
    assert(u.getString(0) == "0" && !u.getBool(0));
}

// Golden bytes from `clickhouse client -q "SELECT ... FORMAT Native"` (data part only)
@safe unittest
{
    import clickhoused.io.mock : MockTransport;

    // SELECT toInt128(-2)
    auto t = new MockTransport;
    ubyte[] minusTwo = [0xFE];
    foreach (i; 1 .. 16)
        minusTwo ~= 0xFF;
    t.feed(minusTwo);
    auto c = new Int128Column("i", "Int128");
    c.readData(new BufferedReader(t), 1);
    assert(c.getString(0) == "-2" && t.remaining == 0);

    auto w = new MockTransport;
    auto writer = new BufferedWriter(w);
    c.writeData(writer);
    writer.flush();
    assert(w.written == minusTwo);
}
