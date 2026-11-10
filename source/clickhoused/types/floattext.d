/++
Text of floating-point values as ClickHouse writes it: the shortest decimal
that reads back as the same value, in plain notation for moderate magnitudes
(`0.000001`, `100000000000000000000`) and with an exponent otherwise (`1e-7`,
`1.5e21`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.floattext;

import dbwire.types.floattext : FloatLayout, formatDigits, shortestDigits;
import dbwire.types.text : TextBuffer;

/++
`value` as ClickHouse formats a `Float32` (for `float`) or `Float64` (for
`double`): `nan` for any NaN, `inf`, `-inf`, `-0` for negative zero.
+/
package(clickhoused) string formatFloat(T)(T value) @safe pure if (is(T == float) || is(T == double))
{
    import std.math : isInfinity, isNaN, signbit;

    if (isNaN(value))
        return "nan";
    if (isInfinity(value))
        return value > 0 ? "inf" : "-inf";
    const negative = signbit(value) != 0;
    if (value == 0)
        return negative ? "-0" : "0";

    // Whole numbers below 2^53 (2^24 for float) are exact, and their digits are the shortest text
    enum T exactLimit = 2.0 ^^ (T.mant_dig);
    if (value > -exactLimit && value < exactLimit && value == cast(long) value)
    {
        TextBuffer!24 t;
        if (negative)
            t.put('-');
        t.number(value < 0 ? -cast(long) value : cast(long) value);
        return t.text;
    }
    return formatDigits(shortestDigits(value), negative, clickHouseLayout);
}

///
@safe unittest
{
    assert(formatFloat(0.1) == "0.1");
    double sum = 0.1;
    sum += 0.2; // at run time: a constant expression would be folded with real precision
    assert(formatFloat(sum) == "0.30000000000000004");
    assert(formatFloat(0.1f) == "0.1");
    assert(formatFloat(9_999_220_736.0f) == "9999221000");
    assert(formatFloat(1e21) == "1e21");
    assert(formatFloat(1e-7) == "1e-7");
}

/++
ClickHouse's layout: plain notation when the decimal exponent X (the value is
d.ddd × 10^X) is from -6 to 20, otherwise one digit, the rest after a point,
and `e` with the exponent, without `+` or padding (`1e-7`, `1.5e21`).
+/
private enum clickHouseLayout = FloatLayout(-6, 21, false, false, 1);

@safe unittest
{
    // Checked against the server's toString (the same on 23.8 and 26.x)
    assert(formatFloat(-0.0) == "-0" && formatFloat(0.0f) == "0");
    assert(formatFloat(double.nan) == "nan" && formatFloat(-double.nan) == "nan");
    assert(formatFloat(-float.infinity) == "-inf" && formatFloat(double.infinity) == "inf");
    assert(formatFloat(1e20) == "100000000000000000000");
    assert(formatFloat(1.23e21) == "1.23e21");
    assert(formatFloat(1e-6) == "0.000001");
    assert(formatFloat(1.5e-6) == "0.0000015");
    assert(formatFloat(12_345.678) == "12345.678");
    assert(formatFloat(1.2345678901234569e23) == "1.2345678901234569e23");
    assert(formatFloat(1.7976931348623157e308) == "1.7976931348623157e308");
    assert(formatFloat(double.min_normal) == "2.2250738585072014e-308");
    assert(formatFloat(double.min_normal * double.epsilon) == "5e-324"); // smallest subnormal
    assert(formatFloat(float.min_normal * float.epsilon) == "1e-45");
    assert(formatFloat(float.max) == "3.4028235e38");
    assert(formatFloat(9.958967e-11f) == "9.958967e-11");
    assert(formatFloat(-0.33203125f) == "-0.33203125");
    assert(formatFloat(123_207_680.0f) == "123207680");
    assert(formatFloat(16_777_216.0f) == "16777216");
    assert(formatFloat(2.0 ^^ 63) == "9223372036854776000");
    assert(formatFloat(-2.0f ^^ -10) == "-0.0009765625");
}
