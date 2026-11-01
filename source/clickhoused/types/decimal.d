/++
`Decimal(P, S)` columns and the `Decimal` value type.

ClickHouse decimals are fixed-point: an integer of 32, 64, 128 or 256 bits
(chosen by the precision `P`) holding the value times 10^S. The columns keep
those integers as on the wire; `Decimal` holds one value exactly, with its
scale, and converts it to and from text, `double` and `std.bigint.BigInt`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.decimal;

import std.bigint : BigInt;
import std.meta : AliasSeq;
import std.variant : Variant;

import clickhoused.exception : ClientException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column : appendFast, Column, makeVariant, readChunkRows;
import clickhoused.types.wideint : Int128, Int256;

/// Largest precision (and scale) of a ClickHouse decimal.
enum uint maxDecimalPrecision = 76;

/++
An exact decimal number: `unscaled / 10^scale`, e.g. `Decimal(Int256(-150), 2)`
is -1.50.

Comparison and equality are numeric (1.5 equals 1.50). There is no arithmetic:
use `unscaled.toBigInt()` and `scale` to compute.
+/
struct Decimal
{
    /// The value times 10^`scale`.
    Int256 unscaled;
    /// Number of digits after the decimal point, 0 to 76.
    uint scale;

    /++
    Creates a value.

    Throws: `ClientException` if `scale` is above 76.
    +/
    this(Int256 unscaled, uint scale) @safe pure
    {
        if (scale > maxDecimalPrecision)
            throw new ClientException("Decimal scale out of range: " ~ toText(scale));
        this.unscaled = unscaled;
        this.scale = scale;
    }

    /++
    Parses decimal text such as `"-12.345"`. The scale is the number of
    digits after the point.

    Throws: `ClientException` if the text is not a decimal number.
    +/
    static Decimal fromString(scope const(char)[] text) @safe
    {
        const parts = splitNumber(text);
        return fromParts(text, parts, cast(uint) parts.fraction.length);
    }

    /++
    Parses decimal text at the given scale. Digits beyond the scale are
    truncated (towards zero), as ClickHouse does; missing ones are zeros.

    Throws: `ClientException` if the text is not a decimal number or does not
    fit in 76 digits.
    +/
    static Decimal fromString(scope const(char)[] text, uint scale) @safe
    {
        return fromParts(text, splitNumber(text), scale);
    }

    /++
    Converts a `double`, truncating it to `scale` digits after the point.

    Throws: `ClientException` if `value` is not finite or too large.
    +/
    static Decimal fromDouble(double value, uint scale) @safe
    {
        import std.format : format;
        import std.math : isFinite;

        if (!isFinite(value))
            throw new ClientException("Cannot convert " ~ toText(value) ~ " to a decimal");
        // 17 significant digits identify the double exactly, without an exponent
        return fromString(format("%.*f", scale + 17, value), scale);
    }

    /++
    The value as ClickHouse prints it: trailing zeros after the point are
    dropped, e.g. `"1.5"` for 1.50 and `"100"` for 100.00.
    +/
    string toString() const @safe pure nothrow
    {
        auto digits = unscaled.toString();
        const negative = digits[0] == '-';
        if (negative)
            digits = digits[1 .. $];
        if (scale == 0)
            return (negative ? "-" : "") ~ digits;
        while (digits.length <= scale)
            digits = "0" ~ digits;
        auto integer = digits[0 .. $ - scale];
        auto fraction = digits[$ - scale .. $];
        while (fraction.length && fraction[$ - 1] == '0')
            fraction = fraction[0 .. $ - 1];
        return (negative ? "-" : "") ~ integer ~ (fraction.length ? "." ~ fraction : "");
    }

    /// The value with exactly `scale` digits after the point, e.g. `"1.50"`.
    string toFixedString() const @safe pure nothrow
    {
        auto digits = unscaled.toString();
        const negative = digits[0] == '-';
        if (negative)
            digits = digits[1 .. $];
        if (scale == 0)
            return (negative ? "-" : "") ~ digits;
        while (digits.length <= scale)
            digits = "0" ~ digits;
        return (negative ? "-" : "") ~ digits[0 .. $ - scale] ~ "." ~ digits[$ - scale .. $];
    }

    /// The value as a `double` (rounded).
    double toDouble() const @safe
    {
        import std.conv : to;

        return toFixedString().to!double;
    }

    /++
    The value at another scale; digits beyond it are truncated (towards zero).

    Throws: `ClientException` if the result does not fit in 76 digits.
    +/
    Decimal rescaled(uint newScale) const @safe
    {
        if (newScale == scale)
            return this;
        if (newScale > maxDecimalPrecision)
            throw new ClientException("Decimal scale out of range: " ~ toText(newScale));
        auto value = unscaled.toBigInt();
        if (newScale > scale)
            value *= BigInt(10) ^^ (newScale - scale);
        else
            value /= BigInt(10) ^^ (scale - newScale); // BigInt division truncates towards zero
        return Decimal(toUnscaled(value), newScale);
    }

    /// Numeric comparison, also across scales.
    int opCmp(const Decimal other) const @safe
    {
        if (scale == other.scale)
            return unscaled.opCmp(other.unscaled);
        auto a = unscaled.toBigInt();
        auto b = other.unscaled.toBigInt();
        if (scale < other.scale)
            a *= BigInt(10) ^^ (other.scale - scale);
        else
            b *= BigInt(10) ^^ (scale - other.scale);
        return a < b ? -1 : a > b ? 1 : 0;
    }

    /// Numeric equality: 1.5 equals 1.50.
    bool opEquals(const Decimal other) const @safe
    {
        return opCmp(other) == 0;
    }

    /// Hash consistent with numeric equality.
    size_t toHash() const @safe nothrow
    {
        return hashOf(toString());
    }

    private static Decimal fromParts(scope const(char)[] text, const NumberParts parts, uint scale) @safe
    {
        if (scale > maxDecimalPrecision)
            throw new ClientException("Decimal scale out of range: " ~ toText(scale));
        auto fraction = parts.fraction.length > scale ? parts.fraction[0 .. scale] : parts.fraction;
        auto digits = parts.integer ~ fraction;
        foreach (i; fraction.length .. scale)
            digits ~= '0';
        // At most 76 significant digits
        size_t first;
        while (first + 1 < digits.length && digits[first] == '0')
            first++;
        if (digits.length - first > maxDecimalPrecision)
            throw new ClientException("Decimal value too large: '" ~ text.idup ~ "'");
        auto unscaled = Int256.fromString((parts.negative ? "-" : "") ~ digits);
        return Decimal(unscaled, scale);
    }
}

///
@safe unittest
{
    const price = Decimal.fromString("19.90");
    assert(price.scale == 2 && price.unscaled == Int256(1990));
    assert(price.toString() == "19.9" && price.toFixedString() == "19.90");
    assert(price == Decimal.fromString("19.9")); // numeric equality
    assert(Decimal.fromString("1.555", 2).toString() == "1.55"); // truncated, as ClickHouse does
}

/// The parts of decimal text: sign, digits before and after the point.
private struct NumberParts
{
    bool negative;
    const(char)[] integer;
    const(char)[] fraction;
}

private NumberParts splitNumber(scope return const(char)[] text) @safe
{
    ClientException error()
    {
        return new ClientException("Cannot parse '" ~ text.idup ~ "' as a decimal number");
    }

    NumberParts parts;
    size_t pos;
    if (text.length && (text[0] == '-' || text[0] == '+'))
    {
        parts.negative = text[0] == '-';
        pos = 1;
    }
    const start = pos;
    while (pos < text.length && text[pos] >= '0' && text[pos] <= '9')
        pos++;
    parts.integer = text[start .. pos];
    if (pos < text.length && text[pos] == '.')
    {
        const fractionStart = ++pos;
        while (pos < text.length && text[pos] >= '0' && text[pos] <= '9')
            pos++;
        parts.fraction = text[fractionStart .. pos];
    }
    if (pos != text.length || parts.integer.length + parts.fraction.length == 0)
        throw error();
    if (parts.integer.length == 0)
        parts.integer = "0";
    return parts;
}

/// Converts an unscaled `BigInt` to `Int256`, checking the 76-digit limit.
private Int256 toUnscaled(const BigInt value) @safe
{
    import std.bigint : toDecimalString;

    auto text = value.toDecimalString();
    const digits = text[0] == '-' ? text[1 .. $] : text;
    if (digits.length > maxDecimalPrecision)
        throw new ClientException("Decimal value too large: " ~ text);
    return Int256.fromBigInt(value);
}

private string toText(T)(T value) @safe
{
    import std.conv : to;

    return value.to!string;
}

@safe unittest
{
    import std.exception : assertThrown;

    // Formatting as ClickHouse does (checked on 23.8 and 26.11)
    assert(Decimal.fromString("-0.05").toString() == "-0.05");
    assert(Decimal(Int256(0), 4).toString() == "0" && Decimal(Int256(100), 0).toString() == "100");
    assert(Decimal(Int256(1_000_000_000), 9).toString() == "1");
    assert(Decimal.fromString("-12345678901234567890.123456789").toString() == "-12345678901234567890.123456789");
    assert(Decimal(Int256(-5), 3).toFixedString() == "-0.005");

    // Parsing
    assert(Decimal.fromString("+.5").toString() == "0.5" && Decimal.fromString("7.").toString() == "7");
    assert(Decimal.fromString("-1.555", 2).toString() == "-1.55");
    assert(Decimal.fromString("1.5", 4).unscaled == Int256(15_000));
    foreach (bad; ["", "-", ".", "1e5", " 1", "1.2.3", "abc", "1,5"])
        assertThrown!ClientException(Decimal.fromString(bad), bad);
    char[77] tooLong = '9';
    assertThrown!ClientException(Decimal.fromString(tooLong[]));
    assert(Decimal.fromString(tooLong[0 .. 76]).toString().length == 76);

    // Rescaling, comparison, doubles
    assert(Decimal.fromString("1.999").rescaled(1).toString() == "1.9");
    assert(Decimal.fromString("-1.999").rescaled(0).toString() == "-1");
    assert(Decimal.fromString("2.5").rescaled(3).unscaled == Int256(2500));
    assert(Decimal.fromString("1.5") < Decimal.fromString("1.51"));
    assert(Decimal.fromString("-2") < Decimal.fromString("1"));
    assert(Decimal.fromString("1.50").toHash() == Decimal.fromString("1.5").toHash());
    assert(Decimal.fromDouble(0.1, 2).toString() == "0.1" && Decimal.fromDouble(-2.675, 2).toString() == "-2.67");
    assert(Decimal.fromString("-2.25").toDouble() == -2.25);
    assertThrown!ClientException(Decimal.fromDouble(double.nan, 2));
}

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

/// The decimal in `row` if `column` is any `DecimalColumn`; returns false otherwise.
package(clickhoused) bool decimalAt(const Column column, size_t row, out Decimal value) @safe
{
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
    assert((() @trusted => c.getVariant(0).get!Decimal)() == Decimal.fromString("1.55")); // Variant.get is not @safe

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
