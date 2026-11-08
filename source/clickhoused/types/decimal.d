/++
`Decimal(P, S)` columns. The `Decimal` value type moved to
`dbwire.types.decimal` (package dbwire) in 0.9 and is re-exported here.

ClickHouse decimals are fixed-point: an integer of 32, 64, 128 or 256 bits
(chosen by the precision `P`) holding the value times 10^S. The columns keep
those integers as on the wire; `Decimal` holds one value exactly, with its
scale, and converts it to and from text, `double` and `std.bigint.BigInt`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.decimal;

public import dbwire.types.decimal;

import std.meta : AliasSeq;
import std.variant : Variant;

import clickhoused.exception : ClientException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column : appendFast, Column, makeVariant, readChunkRows;
import clickhoused.types.wideint : Int128, Int256;

/// Largest precision (and scale) of a ClickHouse decimal.
enum uint maxDecimalPrecision = 76;

/// `Decimal(P, S)` column; `T` is the storage: `int`, `long`, `Int128` or `Int256`.
final class DecimalColumn(T) : Column if (is(T == int) || is(T == long) || is(T == Int128) || is(T == Int256))
{
    /// The values times 10^`scale`, as on the wire.
    T[] data;
    private T[] spare; // room for appends; see `appendFast`
    /// Precision: total number of digits.
    immutable uint precision;
    /// Scale: digits after the point.
    immutable uint scale;

    private Int256 maxUnscaled; // 10^precision - 1

    /++
    Creates an empty column.

    Throws: `ClientException` if the precision does not fit the storage type
    or the scale exceeds the precision.
    +/
    this(string name, string typeName, uint precision, uint scale) @safe
    {
        super(name, typeName);
        if (precision == 0 || precision > storagePrecision || scale > precision)
            throw new ClientException("Invalid decimal type '" ~ typeName ~ "'");
        this.precision = precision;
        this.scale = scale;
        char[maxDecimalPrecision] nines = '9';
        maxUnscaled = Int256.fromString(nines[0 .. precision]);
    }

    /// Largest precision of the storage type.
    enum uint storagePrecision = T.sizeof == 4 ? 9 : T.sizeof == 8 ? 18 : T.sizeof == 16 ? 38 : 76;

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
                {
                    static if (is(T == int) || is(T == long))
                        v = reader.readFixed!T();
                    else
                        foreach (ref w; v.words)
                            w = reader.readFixed!ulong();
                }
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
            {
                static if (is(T == int) || is(T == long))
                    writer.writeFixed(v);
                else
                    foreach (w; v.words)
                        writer.writeFixed(w);
            }
        }
    }

    /// The value in `row`.
    Decimal opIndex(size_t row) const @safe
    {
        return Decimal(widen(data[row]), scale);
    }

    /// The value as ClickHouse prints it (no trailing zeros after the point).
    override string getString(size_t row) const @safe
    {
        return this[row].toString();
    }

    override double getDouble(size_t row) const @safe
    {
        return this[row].toDouble();
    }

    /// Only whole values that fit.
    override long getLong(size_t row) const @safe
    {
        const value = this[row];
        const whole = value.rescaled(0);
        if (whole != value)
            throw conversionError(row, "long");
        try
            return whole.unscaled.toLong();
        catch (ClientException)
            throw conversionError(row, "long");
    }

    /// Only whole values that fit.
    override ulong getUlong(size_t row) const @safe
    {
        const value = this[row];
        const whole = value.rescaled(0);
        if (whole != value)
            throw conversionError(row, "ulong");
        try
            return whole.unscaled.toUlong();
        catch (ClientException)
            throw conversionError(row, "ulong");
    }

    override bool getBool(size_t row) const @safe
    {
        return data[row] != T.init;
    }

    /// A `Variant` holding a `Decimal`.
    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(this[row]);
    }

    override void truncate(size_t length) @safe
    {
        if (length < data.length)
            data.length = length;
    }

    override void appendDefault() @safe
    {
        appendFast(data, spare, T.init);
    }

    /++
    Appends `value`, converted to the column's scale (extra digits are
    truncated, as ClickHouse does).

    Throws: `ClientException` if it exceeds the precision.
    +/
    void appendDecimal(const Decimal value) @safe
    {
        Decimal scaled;
        try
            scaled = value.rescaled(scale);
        catch (ClientException)
            throw appendError("decimal", value);
        const v = scaled.unscaled;
        if (v > maxUnscaled || v < negativeMax())
            throw appendError("decimal", value);
        appendFast(data, spare, narrow(v));
    }

    override void appendLong(long value) @safe
    {
        appendDecimal(Decimal(Int256(value), 0));
    }

    override void appendUlong(ulong value) @safe
    {
        appendDecimal(Decimal(Int256(value), 0));
    }

    /// Truncated to the column's scale.
    override void appendDouble(double value) @safe
    {
        Decimal d;
        try
            d = Decimal.fromDouble(value, scale);
        catch (ClientException)
            throw appendError("double", value);
        appendDecimal(d);
    }

    override void appendBool(bool value) @safe
    {
        appendLong(value ? 1 : 0);
    }

    /// Parses decimal text; digits beyond the scale are truncated, as ClickHouse does.
    override void appendString(string value) @safe
    {
        Decimal d;
        try
            d = Decimal.fromString(value, scale);
        catch (ClientException)
            throw appendError("string", value);
        appendDecimal(d);
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        auto other = sameKind!DecimalColumn(source);
        if (other.scale != scale || other.precision != precision)
            throw new ClientException("Column '" ~ name ~ "': cannot copy values of a different decimal type");
        appendFast(data, spare, other.data[row]);
    }

    private Int256 negativeMax() const @safe pure
    {
        return Int256.fromString("-" ~ maxUnscaled.toString());
    }

    private static Int256 widen(const T raw) @safe pure
    {
        static if (is(T == Int256))
            return raw;
        else static if (is(T == Int128))
        {
            Int256 result;
            result.words[0 .. 2] = raw.words[];
            if (raw.isNegative)
                result.words[2 .. 4] = ulong.max;
            return result;
        }
        else
            return Int256(raw);
    }

    /// Narrows a value already checked against the precision, so it fits.
    private static T narrow(const Int256 value) @safe pure nothrow
    {
        static if (is(T == Int256))
            return value;
        else static if (is(T == Int128))
        {
            Int128 result;
            result.words[] = value.words[0 .. 2];
            return result;
        }
        else
            return cast(T) cast(long) value.words[0];
    }
}

/++
The decimal in `row` if `column` is any `DecimalColumn`, also inside
`Nullable` and `LowCardinality` (whose values are a column of the inner type,
row for row); returns false otherwise. The caller checks for NULL first.
+/
package(clickhoused) bool decimalAt(const Column column, size_t row, out Decimal value) @safe
{
    import clickhoused.types.lowcardinality : LowCardinalityColumn;
    import clickhoused.types.misc : NullableColumn;

    if (auto n = cast(const NullableColumn) column)
        return decimalAt(n.nested, row, value);
    if (auto lc = cast(const LowCardinalityColumn) column)
        return decimalAt(lc.values, row, value);
    static foreach (T; AliasSeq!(int, long, Int128, Int256))
        if (auto c = cast(const DecimalColumn!T) column)
            {
            value = c[row];
            return true;
        }
    return false;
}

/// Appends `value` if `column` is any `DecimalColumn`; returns false otherwise.
package(clickhoused) bool appendDecimalTo(Column column, const Decimal value) @safe
{
    static foreach (T; AliasSeq!(int, long, Int128, Int256))
        if (auto c = cast(DecimalColumn!T) column)
            {
            c.appendDecimal(value);
            return true;
        }
    return false;
}

/// `Decimal(P, S)` with P up to 9.
alias Decimal32Column = DecimalColumn!int;
/// `Decimal(P, S)` with P up to 18.
alias Decimal64Column = DecimalColumn!long;
/// `Decimal(P, S)` with P up to 38.
alias Decimal128Column = DecimalColumn!Int128;
/// `Decimal(P, S)` with P up to 76.
alias Decimal256Column = DecimalColumn!Int256;

@safe unittest
{
    import std.exception : assertThrown;

    auto c = new Decimal32Column("p", "Decimal(9, 2)", 9, 2);
    c.appendString("1.555"); // truncated to 1.55
    c.appendLong(-3);
    c.appendDouble(0.1);
    c.appendDecimal(Decimal.fromString("9999999.99"));
    assert(c.data == [155, -300, 10, 999_999_999]);
    assert(c.getString(0) == "1.55" && c.getString(1) == "-3" && c.getString(2) == "0.1");
    assert(c.getLong(1) == -3 && c.getDouble(0) == 1.55);
    assertThrown!ClientException(c.getLong(0)); // not whole
    assertThrown!ClientException(c.appendString("10000000")); // more than 9 digits
    assertThrown!ClientException(c.appendString("x"));
    assertThrown!ClientException(c.appendDouble(double.infinity));
    assert(c.length == 4); // failed appends add nothing
    // Variant.get is not @safe. Take the value into a variable first: comparing the lambda's
    // result directly gives false with DMD 2.105 to 2.109 (fine with LDC and other DMDs)
    const fromVariant = (() @trusted => c.getVariant(0).get!Decimal)();
    assert(fromVariant == Decimal.fromString("1.55"));

    auto wide = new Decimal256Column("w", "Decimal(76, 40)", 76, 40);
    wide.appendString("-123456789012345678901234567890123456.1234567890123456789012345678901234567890");
    assert(wide.getString(0) == "-123456789012345678901234567890123456.123456789012345678901234567890123456789");
    auto mid = new Decimal128Column("m", "Decimal(38, 0)", 38, 0);
    mid.appendString("-99999999999999999999999999999999999999");
    assert(mid.getString(0) == "-99999999999999999999999999999999999999");
    assertThrown!ClientException(mid.appendString("100000000000000000000000000000000000000"));

    assertThrown!ClientException(new Decimal32Column("x", "Decimal(10, 2)", 10, 2));
    assertThrown!ClientException(new Decimal64Column("x", "Decimal(5, 6)", 5, 6));
}

// Golden bytes from `clickhouse client -q "SELECT toDecimal64(-1.5, 3) FORMAT Native"` (data part)
@safe unittest
{
    import clickhoused.io.mock : MockTransport;

    const bytes = cast(const(ubyte)[])[0x24, 0xfa, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff];
    auto t = new MockTransport;
    t.feed(bytes);
    auto c = new Decimal64Column("d", "Decimal(18, 3)", 18, 3);
    c.readData(new BufferedReader(t), 1);
    assert(c.getString(0) == "-1.5" && c.data == [-1500]);

    auto w = new MockTransport;
    auto writer = new BufferedWriter(w);
    c.writeData(writer);
    writer.flush();
    assert(w.written == bytes);
}
