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

    override void appendDefault() @safe
    {
        data ~= cast(T) 0;
    }

    override void appendLong(long value) @safe
    {
        static if (isFloatingPoint!T)
            data ~= cast(T) value;
        else static if (isSigned!T)
        {
            if (value < T.min || value > T.max)
                throw appendError("long", value);
            data ~= cast(T) value;
        }
        else
        {
            if (value < 0 || cast(ulong) value > T.max)
                throw appendError("long", value);
            data ~= cast(T) value;
        }
    }

    override void appendUlong(ulong value) @safe
    {
        static if (isFloatingPoint!T)
            data ~= cast(T) value;
        else
        {
            if (value > T.max)
                throw appendError("ulong", value);
            data ~= cast(T) value;
        }
    }

    /// For integer columns, only whole numbers within the type's range are accepted.
    override void appendDouble(double value) @safe
    {
        static if (isFloatingPoint!T)
            data ~= cast(T) value;
        else
        {
            import std.math : trunc;

            enum double upper = 2.0 ^^ (T.sizeof * 8 - (isSigned!T ? 1 : 0));
            enum double lower = isSigned!T ? -upper : 0;
            if (!(value >= lower && value < upper) || value != trunc(value))
                throw appendError("double", value);
            data ~= cast(T) value;
        }
    }

    override void appendBool(bool value) @safe
    {
        data ~= cast(T)(value ? 1 : 0);
    }

    /// Parses `value` as a number.
    override void appendString(string value) @safe
    {
        import std.conv : ConvException, to;

        try
            data ~= value.to!T;
        catch (ConvException)
            throw appendError("string", value);
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

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.exception : ClientException;

    // Range-checked appends
    auto b = new UInt8Column("b", "UInt8");
    b.appendLong(255);
    b.appendUlong(0);
    b.appendDouble(7);
    b.appendString("12");
    b.appendBool(true);
    b.appendDefault();
    assert(b.data == [255, 0, 7, 12, 1, 0]);
    assertThrown!ClientException(b.appendLong(256));
    assertThrown!ClientException(b.appendLong(-1));
    assertThrown!ClientException(b.appendDouble(1.5));
    assertThrown!ClientException(b.appendString("x"));
    assertThrown!ClientException(b.appendNull());

    auto u = new UInt64Column("u", "UInt64");
    u.appendUlong(ulong.max);
    assertThrown!ClientException(u.appendDouble(18_446_744_073_709_551_616.0)); // 2^64
    auto i = new Int64Column("i", "Int64");
    i.appendDouble(-9_223_372_036_854_775_808.0); // -2^63 fits
    assertThrown!ClientException(i.appendUlong(ulong.max));
    auto f = new Float32Column("f", "Float32");
    f.appendDefault();
    assert(f.data == [0]); // not NaN
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

    override void appendDefault() @safe
    {
        data ~= false;
    }

    override void truncate(size_t length) @safe
    {
        if (length < data.length)
            data.length = length;
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        data ~= sameKind!BoolColumn(source).data[row];
    }

    override void appendBool(bool value) @safe
    {
        data ~= value;
    }

    /// Accepts 0 and 1.
    override void appendLong(long value) @safe
    {
        if (value != 0 && value != 1)
            throw appendError("long", value);
        data ~= value == 1;
    }

    /// Accepts 0 and 1.
    override void appendUlong(ulong value) @safe
    {
        if (value > 1)
            throw appendError("ulong", value);
        data ~= value == 1;
    }

    /// Accepts `"true"`, `"false"`, `"1"` and `"0"`.
    override void appendString(string value) @safe
    {
        switch (value)
        {
        case "true":
        case "1":
            data ~= true;
            break;
        case "false":
        case "0":
            data ~= false;
            break;
        default:
            throw appendError("string", value);
        }
    }
}
