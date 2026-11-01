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
integer arithmetic: `r / s` is the value, `mPlus / s` and `mMinus / s` are
the distances to the midpoints between `value` and its neighbours. Ties when
reading text round to even, so the midpoints themselves read back as `value`
when its mantissa is even. It runs on 128-bit integers when the numbers fit
(nearly every `float`, doubles from about 1e-20 to 1e35), and on `BigInt`
otherwise; both give the same digits.
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
    DigitInput input;
    input.f = rep.fraction;
    if (rep.exponent == 0)
        input.e = 1 - bias - mantissaBits; // subnormal
    else
    {
        input.f |= 1UL << mantissaBits;
        input.e = rep.exponent - bias - mantissaBits;
    }
    input.even = (input.f & 1) == 0;
    // At a power of two the neighbour below is closer: half the gap above
    input.narrowBelow = rep.fraction == 0 && rep.exponent > 1;
    // An estimate of the decimal exponent; the digit generation corrects it exactly
    input.k = cast(int) ceil(log10(cast(double) value) - 1e-10);

    ShortestDigits result;
    const generated = generateDigits!U128(input, result) || generateDigits!BigInt(input, result);
    assert(generated, "the digit generation failed");
    return result;
}

/// The value `f × 2^e` to generate digits for, and its properties; see `shortestDigits`.
private struct DigitInput
{
    ulong f; // mantissa, with the hidden bit
    int e; // binary exponent
    bool even; // whether `f` is even: ties then read back as the value
    bool narrowBelow; // at a power of two: the gap to the next smaller value is half the one above
    int k; // estimated decimal exponent
}

/++
Generates the digits of `input` with integers of type `N` (`U128` or
`BigInt`). Returns: false if `U128` overflowed (nothing is set then).
+/
private bool generateDigits(N)(const DigitInput input, out ShortestDigits result) @safe pure
{
    N r = N(input.f), s = N(1), mPlus = N(1), mMinus = N(1);
    bool failed()
    {
        static if (is(N == U128))
            return r.bad || s.bad || mPlus.bad || mMinus.bad;
        else
            return false;
    }

    if (input.e >= 0)
    {
        r <<= input.e;
        mPlus <<= input.e;
        mMinus <<= input.e;
    }
    else
        s <<= -input.e;
    // Scale by 2 (by 4 at a power of two) so that the half gaps are whole numbers
    r <<= input.narrowBelow ? 2 : 1;
    s <<= input.narrowBelow ? 2 : 1;
    if (input.narrowBelow)
        mPlus <<= 1;

    int k = input.k;
    if (k >= 0)
        multiplyByPow10(s, k);
    else
    {
        multiplyByPow10(r, -k);
        multiplyByPow10(mPlus, -k);
        multiplyByPow10(mMinus, -k);
    }
    if (failed())
        return false;
    bool aboveTop()
    {
        const top = r + mPlus;
        return input.even ? top >= s : top > s;
    }

    while (aboveTop())
    {
        s *= 10;
        k++;
        if (failed())
            return false;
    }
    for (;;)
    {
        const top = (r + mPlus) * 10;
        static if (is(N == U128))
            if (top.bad)
                return false;
        if (input.even ? top >= s : top > s)
            break;
        r *= 10;
        mPlus *= 10;
        mMinus *= 10;
        k--;
        if (failed())
            return false;
    }

    char[24] buffer = void; // at most 17 significant digits for a double, 9 for a float
    size_t count;
    for (;;)
    {
        if (count == buffer.length)
            return false; // cannot happen for shortest digits; never write past the buffer
        r *= 10;
        mPlus *= 10;
        mMinus *= 10;
        int d = takeDigit(r, s);
        const top = r + mPlus;
        if (failed() || d > 9)
            return false;
        static if (is(N == U128))
            if (top.bad)
                return false;
        const low = input.even ? r <= mMinus : r < mMinus;
        const high = input.even ? top >= s : top > s;
        if (!low && !high)
        {
            buffer[count++] = cast(char)('0' + d);
            continue;
        }
        if (high && !low)
            d++;
        else if (high && low)
        {
            // Both last digits read back: take the closer one, the even one on a tie
            const twice = r + r;
            static if (is(N == U128))
                if (twice.bad)
                    return false;
            if (twice > s || (twice == s && (d & 1) != 0))
                d++;
        }
        buffer[count++] = cast(char)('0' + d);
        break;
    }
    result = carry(buffer[0 .. count], k);
    return true;
}

/// `x × 10^n`.
private void multiplyByPow10(N)(ref N x, int n) @safe pure
{
    static if (is(N == BigInt))
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
        x *= p;
    }
    else
    {
        for (; n >= 19; n -= 19)
            x *= 10_000_000_000_000_000_000UL;
        ulong p = 1;
        foreach (_; 0 .. n)
            p *= 10;
        x *= p;
    }
}

/// The digit `r / s` (below 10 when the digit generation is right), leaving the remainder in `r`.
private int takeDigit(N)(ref N r, N s) @safe pure
{
    static if (is(N == BigInt))
    {
        const q = r / s;
        r -= q * s;
        return cast(int) q.toLong();
    }
    else
    {
        int q;
        while (r >= s && q < 10)
        {
            r = r - s;
            q++;
        }
        return q;
    }
}

/++
An unsigned 128-bit integer with the operations of the digit generation.
An operation whose result does not fit sets `bad`, which every later result
inherits; the caller then starts again with `BigInt`.
+/
private struct U128
{
    ulong hi; ///
    ulong lo; ///
    bool bad; /// a result did not fit: the value is meaningless

    this(ulong value) @safe pure nothrow @nogc
    {
        lo = value;
    }

    U128 opBinary(string op : "+")(const U128 b) const @safe pure nothrow @nogc
    {
        U128 sum;
        sum.lo = lo + b.lo;
        const carry = sum.lo < lo ? 1 : 0;
        sum.hi = hi + b.hi + carry;
        sum.bad = bad || b.bad || sum.hi < hi || (sum.hi == hi && (b.hi != 0 || carry != 0));
        return sum;
    }

    /// `this - b`, for `this >= b`.
    U128 opBinary(string op : "-")(const U128 b) const @safe pure nothrow @nogc
    {
        U128 difference;
        difference.lo = lo - b.lo;
        difference.hi = hi - b.hi - (lo < b.lo ? 1 : 0);
        difference.bad = bad || b.bad;
        return difference;
    }

    U128 opBinary(string op : "*")(ulong m) const @safe pure nothrow @nogc
    {
        const low = multiply(lo, m);
        const high = multiply(hi, m);
        U128 product;
        product.lo = low.low;
        product.hi = high.low + low.high;
        product.bad = bad || high.high != 0 || product.hi < high.low;
        return product;
    }

    void opOpAssign(string op : "*")(ulong m) @safe pure nothrow @nogc
    {
        this = this * m;
    }

    void opOpAssign(string op : "<<")(int n) @safe pure nothrow @nogc
    {
        if (n == 0)
            return;
        if (n >= 128)
        {
            bad = bad || hi != 0 || lo != 0;
            hi = lo = 0;
            return;
        }
        if (n >= 64)
        {
            bad = bad || hi != 0 || (n > 64 && (lo >> (128 - n)) != 0);
            hi = lo << (n - 64);
            lo = 0;
            return;
        }
        bad = bad || (hi >> (64 - n)) != 0;
        hi = hi << n | lo >> (64 - n);
        lo <<= n;
    }

    int opCmp(const U128 b) const @safe pure nothrow @nogc
    {
        if (hi != b.hi)
            return hi < b.hi ? -1 : 1;
        return lo < b.lo ? -1 : lo > b.lo ? 1 : 0;
    }

    bool opEquals(const U128 b) const @safe pure nothrow @nogc
    {
        return hi == b.hi && lo == b.lo;
    }

    size_t toHash() const @safe pure nothrow @nogc
    {
        return cast(size_t)(hi ^ lo);
    }

    /// The two 64-bit halves of a 128-bit product.
    private static struct Product
    {
        ulong high;
        ulong low;
    }

    /// `a × b`.
    private static Product multiply(ulong a, ulong b) @safe pure nothrow @nogc
    {
        const aLow = a & 0xFFFF_FFFF, aHigh = a >> 32;
        const bLow = b & 0xFFFF_FFFF, bHigh = b >> 32;
        const ll = aLow * bLow, lh = aLow * bHigh, hl = aHigh * bLow, hh = aHigh * bHigh;
        const middle = (ll >> 32) + (lh & 0xFFFF_FFFF) + (hl & 0xFFFF_FFFF);
        return Product(hh + (lh >> 32) + (hl >> 32) + (middle >> 32), (middle << 32) | (ll & 0xFFFF_FFFF));
    }
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

@safe unittest
{
    import std.math : ceil, ldexp, log10;

    // The 128-bit path, where it fits, gives exactly the digits of the BigInt path
    size_t fast;
    foreach (exponent; -120 .. 130)
        foreach (j; 1 .. 40)
        {
            const value = ldexp(1.0 + j / 41.0, exponent);
            DigitInput input;
            import std.bitmanip : DoubleRep;

            DoubleRep rep;
            rep.value = value;
            input.f = rep.fraction | (1UL << 52);
            input.e = rep.exponent - 1023 - 52;
            input.even = (input.f & 1) == 0;
            input.narrowBelow = rep.fraction == 0 && rep.exponent > 1;
            input.k = cast(int) ceil(log10(value) - 1e-10);
            ShortestDigits viaU128, viaBigInt;
            assert(generateDigits!BigInt(input, viaBigInt));
            if (generateDigits!U128(input, viaU128))
            {
                fast++;
                assert(viaU128 == viaBigInt);
            }
        }
    assert(fast > 5000); // most of these magnitudes take the fast path

    // U128 arithmetic and overflow detection
    auto x = U128(ulong.max);
    x *= 10;
    assert(!x.bad && x.hi == 9 && x.lo == ulong.max - 9);
    auto y = x;
    y <<= 60;
    assert(!y.bad);
    y <<= 8;
    assert(y.bad);
    auto big = U128(1);
    big <<= 127;
    assert(!big.bad && (big + big).bad && !(big + U128(1)).bad);
    assert((big * 2).bad && (U128(5) - U128(3)) == U128(2) && U128(3) < U128(5));
}
