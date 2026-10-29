/++
Numeric and boolean columns: `UInt8`…`UInt64`, `Int8`…`Int64`, `Float32`,
`Float64` and `Bool`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.numeric;

import std.traits : isFloatingPoint, isIntegral, isSigned;
import std.variant : Variant;

import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column;

/// Column of numbers stored as `T[]`.
final class NumericColumn(T) : FixedColumn!T if (isIntegral!T || isFloatingPoint!T)
{
    /// Creates an empty column.
    this(string name, string typeName) @safe pure nothrow
    {
        super(name, typeName);
    }

    override long getLong(size_t row) const @safe
    {
        const v = data[row];
        static if (isFloatingPoint!T)
        {
            if (v != cast(long) v)
                throw conversionError(row, "long");
            return cast(long) v;
        }
        else static if (T.sizeof == 8 && !isSigned!T)
        {
            if (v > long.max)
                throw conversionError(row, "long");
            return cast(long) v;
        }
        else
            return v;
    }

    override ulong getUlong(size_t row) const @safe
    {
        const v = data[row];
        static if (isFloatingPoint!T)
        {
            if (v < 0 || v != cast(ulong) v)
                throw conversionError(row, "ulong");
            return cast(ulong) v;
        }
        else static if (isSigned!T)
        {
            if (v < 0)
                throw conversionError(row, "ulong");
            return cast(ulong) v;
        }
        else
            return v;
    }

    override double getDouble(size_t row) const @safe
    {
        return data[row];
    }

    override bool getBool(size_t row) const @safe
    {
        return data[row] != 0;
    }

    override string getString(size_t row) const @safe
    {
        import std.conv : to;

        return data[row].to!string;
    }

    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(data[row]);
    }
}

/// `UInt8` column.
alias UInt8Column = NumericColumn!ubyte;
/// `UInt16` column.
alias UInt16Column = NumericColumn!ushort;
/// `UInt32` column.
alias UInt32Column = NumericColumn!uint;
/// `UInt64` column.
alias UInt64Column = NumericColumn!ulong;
/// `Int8` column.
alias Int8Column = NumericColumn!byte;
/// `Int16` column.
alias Int16Column = NumericColumn!short;
/// `Int32` column.
alias Int32Column = NumericColumn!int;
/// `Int64` column.
alias Int64Column = NumericColumn!long;
/// `Float32` column.
alias Float32Column = NumericColumn!float;
/// `Float64` column.
alias Float64Column = NumericColumn!double;

///
@system unittest
{
    auto c = new Int32Column("n", "Int32");
    c.data = [-5, 7];
    assert(c.getLong(0) == -5);
    assert(c.getString(1) == "7");
    assert(c.getVariant(1).get!int == 7);
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.exception : ClientException;

    // Range-checked conversions
    auto u = new UInt64Column("u", "UInt64");
    u.data = [ulong.max, 5];
    assertThrown!ClientException(u.getLong(0));
    assert(u.getUlong(0) == ulong.max && u.getLong(1) == 5);

    auto i = new Int8Column("i", "Int8");
    i.data = [-1];
    assertThrown!ClientException(i.getUlong(0));

    auto f = new Float64Column("f", "Float64");
    f.data = [2.0, 2.5];
    assert(f.getLong(0) == 2 && f.getDouble(1) == 2.5);
    assertThrown!ClientException(f.getLong(1));
    assertThrown!ClientException(f.getSysTime(0));
}

/// `Bool` column (one byte per value on the wire).
final class BoolColumn : Column
{
    /// Column values.
    bool[] data;

    /// Creates an empty column.
    this(string name, string typeName = "Bool") @safe pure nothrow
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
        ubyte[] chunk;
        while (data.length < rows)
        {
            const count = rows - data.length < readChunkRows ? rows - data.length : readChunkRows;
            chunk.length = count;
            reader.readExact(chunk);
            foreach (b; chunk)
                data ~= b != 0;
        }
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        foreach (v; data)
            writer.writeByte(v ? 1 : 0);
    }

    override bool getBool(size_t row) const @safe
    {
        return data[row];
    }

    override long getLong(size_t row) const @safe
    {
        return data[row] ? 1 : 0;
    }

    override ulong getUlong(size_t row) const @safe
    {
        return data[row] ? 1 : 0;
    }

    override string getString(size_t row) const @safe
    {
        return data[row] ? "true" : "false";
    }

    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(data[row]);
    }
}
