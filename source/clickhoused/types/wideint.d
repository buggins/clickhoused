/++
128- and 256-bit integer columns. The value types `Int128`, `UInt128`,
`Int256` and `UInt256` moved to `dbwire.types.wideint` (package dbwire) in 0.9
and are re-exported here.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.wideint;

public import dbwire.types.wideint;

import std.variant : Variant;

import clickhoused.exception : ClientException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column : appendFast, Column, makeVariant, readChunkRows;

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
