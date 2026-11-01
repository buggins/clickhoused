/++
Text of floating-point values as ClickHouse writes it: the shortest decimal
that reads back as the same value, in plain notation for moderate magnitudes
(`0.000001`, `100000000000000000000`) and with an exponent otherwise (`1e-7`,
`1.5e21`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.floattext;

import std.bigint : BigInt;

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
    const sign = signbit(value) ? "-" : "";
    if (value == 0)
        return sign ~ "0";

    // Whole numbers below 2^53 (2^24 for float) are exact, and their digits are the shortest text
    enum T exactLimit = 2.0 ^^ (T.mant_dig);
    if (value > -exactLimit && value < exactLimit && value == cast(long) value)
    {
        import std.conv : to;

        return sign ~ (value < 0 ? -cast(long) value : cast(long) value).to!string;
    }

    const d = shortestDigits(value < 0 ? -value : value);
    return sign ~ layout(d.digits, d.pointPos);
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

/// Digits of a decimal and the position of its decimal point; see `shortestDigits`.
private struct ShortestDigits
{
    string digits;
    int pointPos;
}

/++
The shortest decimal digits that read back as `value` (positive and finite),
the closest one if there are several, with the position of the decimal point:
the value is `0.digits × 10^pointPos`.

This is the free-format digit generation of Steele and White, with exact
big-integer arithmetic: `r / s` is the value, `mPlus / s` and `mMinus / s`
are the distances to the midpoints between `value` and its neighbours.
Ties when reading text round to even, so the midpoints themselves read back
as `value` when its mantissa is even.
+/
private ShortestDigits shortestDigits(T)(T value) @safe pure
{
    import std.math : ceil, log10;

    static if (is(T == float))
    {
        import std.bitmanip : FloatRep;

        enum mantissaBits = 23, bias = 127;
        FloatRep rep;
    }
    else
    {
        import std.bitmanip : DoubleRep;

        enum mantissaBits = 52, bias = 1023;
        DoubleRep rep;
    }
    rep.value = value;
    ulong f = rep.fraction;
    int e;
    if (rep.exponent == 0)
        e = 1 - bias - mantissaBits; // subnormal
    else
    {
        f |= 1UL << mantissaBits;
        e = rep.exponent - bias - mantissaBits;
    }
    const even = (f & 1) == 0;
    // At a power of two the neighbour below is closer: half the gap above
    const narrowBelow = rep.fraction == 0 && rep.exponent > 1;

    BigInt r = f, s = 1, mPlus = 1, mMinus = 1;
    if (e >= 0)
    {
        r <<= e;
        mPlus <<= e;
        mMinus <<= e;
    }
    else
        s <<= -e;
    // Scale by 2 (by 4 at a power of two) so that the half gaps are whole numbers
    r <<= narrowBelow ? 2 : 1;
    s <<= narrowBelow ? 2 : 1;
    if (narrowBelow)
        mPlus <<= 1;

    // Estimate the decimal exponent, then correct it exactly
    int k = cast(int) ceil(log10(cast(double) value) - 1e-10);
    if (k >= 0)
        s *= pow10(k);
    else
    {
        const p = pow10(-k);
        r *= p;
        mPlus *= p;
        mMinus *= p;
    }
    bool aboveTop()
    {
        return even ? r + mPlus >= s : r + mPlus > s;
    }

    while (aboveTop())
    {
        s *= 10;
        k++;
    }
    for (;;)
    {
        const top = (r + mPlus) * 10;
        if (even ? top >= s : top > s)
            break;
        r *= 10;
        mPlus *= 10;
        mMinus *= 10;
        k--;
    }

    char[] digits;
    for (;;)
    {
        r *= 10;
        mPlus *= 10;
        mMinus *= 10;
        const q = r / s;
        r -= q * s;
        int d = cast(int) q.toLong();
        const low = even ? r <= mMinus : r < mMinus;
        const high = even ? r + mPlus >= s : r + mPlus > s;
        if (!low && !high)
        {
            digits ~= cast(char)('0' + d);
            continue;
        }
        if (high && !low)
            d++;
        else if (high && low)
        {
            // Both last digits read back: take the closer one, the even one on a tie
            const twice = r * 2;
            if (twice > s || (twice == s && (d & 1) != 0))
                d++;
        }
        digits ~= cast(char)('0' + d);
        break;
    }
    return carry(digits, k);
}

/// Propagates a last digit of 10 left (moving the point if a new digit appears) and drops trailing zeros.
private ShortestDigits carry(char[] digits, int pointPos) @safe pure
{
    size_t i = digits.length;
    while (i > 0 && digits[i - 1] > '9')
    {
        digits = digits[0 .. i - 1];
        i--;
        if (i == 0)
        {
            digits = ['1'];
            pointPos++;
            break;
        }
        digits[i - 1]++;
    }
    while (digits.length > 1 && digits[$ - 1] == '0')
        digits = digits[0 .. $ - 1];
    return ShortestDigits(digits.idup, pointPos);
}

/// `10^n` as a big integer.
private BigInt pow10(int n) @safe pure
{
    BigInt p = 1;
    BigInt base = 10;
    while (n > 0)
    {
        if (n & 1)
            p *= base;
        base *= base;
        n >>= 1;
    }
    return p;
}

/++
Lays out `digits` with the decimal point at `pointPos` (the value is
`0.digits × 10^pointPos`) the way ClickHouse does: plain notation when
`-6 < pointPos <= 21`, otherwise one digit, the rest after a point, and `e`
with the exponent.
+/
private string layout(string digits, int pointPos) @safe pure
{
    import std.array : replicate;
    import std.conv : to;

    const n = cast(int) digits.length;
    if (pointPos >= n && pointPos <= 21)
        return digits ~ "0".replicate(pointPos - n);
    if (pointPos > 0 && pointPos <= 21)
        return digits[0 .. pointPos] ~ "." ~ digits[pointPos .. $];
    if (pointPos > -6 && pointPos <= 0)
        return "0." ~ "0".replicate(-pointPos) ~ digits;
    return digits[0 .. 1] ~ (n > 1 ? "." ~ digits[1 .. $] : "") ~ "e" ~ (pointPos - 1).to!string;
}

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
