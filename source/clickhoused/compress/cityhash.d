// Copyright (c) 2011 Google, Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
// CityHash, by Geoff Pike and Jyrki Alakuijala.
//
// D port of CityHash version 1.0.2 (CityHash64 and CityHash128), as used by
// ClickHouse in contrib/cityhash102. This is the only third-party code in
// clickhoused; it stays under the MIT license above.

/++
CityHash v1.0.2: the hash ClickHouse uses for the checksums of compressed
blocks (`CityHash128`) and for its `cityHash64` SQL function (`CityHash64`).

Later CityHash versions produce different values; this must stay v1.0.2.
+/
module clickhoused.compress.cityhash;

import std.bitmanip : littleEndianToNative;

/// A 128-bit hash value.
struct UInt128
{
    /// Low 64 bits.
    ulong low;
    /// High 64 bits.
    ulong high;
}

/// CityHash64 v1.0.2 of `s`; equals ClickHouse's `cityHash64(s)` for a string argument.
ulong cityHash64(scope const(ubyte)[] s) @safe pure nothrow @nogc
{
    const len = s.length;
    if (len <= 32)
        return len <= 16 ? hashLen0to16(s) : hashLen17to32(s);
    if (len <= 64)
        return hashLen33to64(s);

    // For strings over 64 bytes we hash the end first, and then as we
    // loop we keep 56 bytes of state: v, w, x, y, and z.
    ulong x = fetch64(s, 0);
    ulong y = fetch64(s, len - 16) ^ k1;
    ulong z = fetch64(s, len - 56) ^ k0;
    Pair v = weakHashLen32WithSeeds(s, len - 64, len, y);
    Pair w = weakHashLen32WithSeeds(s, len - 32, len * k1, k0);
    z += shiftMix(v.second) * k1;
    x = rotate(z + x, 39) * k1;
    y = rotate(y, 33) * k1;

    // Operate on 64-byte chunks, up to the nearest multiple of 64 below len.
    size_t pos;
    size_t left = (len - 1) & ~cast(size_t) 63;
    do
    {
        x = rotate(x + y + v.first + fetch64(s, pos + 16), 37) * k1;
        y = rotate(y + v.second + fetch64(s, pos + 48), 42) * k1;
        x ^= w.second;
        y ^= v.first;
        z = rotate(z ^ w.first, 33);
        v = weakHashLen32WithSeeds(s, pos, v.second * k1, x + w.first);
        w = weakHashLen32WithSeeds(s, pos + 32, z + w.second, y);
        swap(z, x);
        pos += 64;
        left -= 64;
    }
    while (left != 0);
    return hashLen16(hashLen16(v.first, w.first) + shiftMix(y) * k1 + z, hashLen16(v.second, w.second) + x);
}

/// CityHash128 v1.0.2 of `s`.
UInt128 cityHash128(scope const(ubyte)[] s) @safe pure nothrow @nogc
{
    const len = s.length;
    if (len >= 16)
        return cityHash128WithSeed(s[16 .. $], UInt128(fetch64(s, 0) ^ k3, fetch64(s, 8)));
    if (len >= 8)
        return cityHash128WithSeed(null, UInt128(fetch64(s, 0) ^ (len * k0), fetch64(s, len - 8) ^ k1));
    return cityHash128WithSeed(s, UInt128(k0, k1));
}

///
@safe pure nothrow unittest
{
    // Values computed by ClickHouse: SELECT cityHash64('')
    assert(cityHash64(null) == 11_160_318_154_034_397_263UL);
}

@safe pure nothrow unittest
{
    // Checksums of compressed blocks written by `clickhouse compressor --none`,
    // over the 9-byte block header plus n bytes of testData
    static immutable ulong[3][] vectors = [
        [1, 0xfd534cc8373f0579UL, 0x7ebada3eae9adcd1UL],
        [7, 0x9f707a5d4683384aUL, 0xa7a3062bed57ac84UL],
        [8, 0x30fac8d46c1ecb87UL, 0x3336367e6a7c6412UL],
        [15, 0xd9c966b26dd86270UL, 0x7b8a59d6b3a2cbafUL],
        [16, 0xaf828bb838c4f936UL, 0xb65b43125131718cUL],
        [100, 0xf543e676d2c2bfc0UL, 0x34bb580e1efe8f3eUL],
        [127, 0x55359ff85d7cb38bUL, 0x1bafa5b8341b9265UL],
        [128, 0x55046b27d479c9ecUL, 0x29437a781d84b3c9UL],
        [200, 0x50434bfc107bb7f1UL, 0xc4bad8c1f85503f5UL],
        [1000, 0x7e195851503115feUL, 0x7e864b1366379e89UL],
    ];
    foreach (v; vectors)
    {
        const n = cast(uint) v[0];
        ubyte[] block = [0x02]; // method: none
        block ~= nativeLE(n + 9);
        block ~= nativeLE(n);
        block ~= testData(n);
        assert(cityHash128(block) == UInt128(v[1], v[2]));
    }
}

@safe pure nothrow unittest
{
    // SELECT cityHash64(s) for s = testData(n), computed by ClickHouse
    static immutable ulong[2][] vectors = [
        [1, 5_794_063_112_461_746_820UL], [4, 393_774_692_670_703_584UL],
        [8, 5_132_431_749_665_047_122UL],
        [9, 7_398_781_784_434_318_545UL], [16, 6_443_432_869_822_510_055UL],
        [17, 9_613_855_398_305_997_431UL],
        [32, 15_706_440_202_538_506_256UL], [33, 5_760_923_680_776_781_934UL],
        [64, 6_479_002_807_762_387_702UL],
        [65, 9_268_771_785_800_577_684UL], [128, 14_559_237_441_718_595_844UL],
        [299, 10_974_079_556_561_190_896UL],
    ];
    foreach (v; vectors)
        assert(cityHash64(testData(cast(size_t) v[0])) == v[1]);
}

version (unittest)
{
    /// Deterministic test input: byte i is (i*i + 7*i + 3) mod 256.
    private ubyte[] testData(size_t n) @safe pure nothrow
    {
        auto d = new ubyte[n];
        foreach (i, ref b; d)
            b = cast(ubyte)(i * i + 7 * i + 3);
        return d;
    }

    private ubyte[4] nativeLE(uint v) @safe pure nothrow
    {
        import std.bitmanip : nativeToLittleEndian;

        return nativeToLittleEndian(v);
    }
}

private:

// Some primes between 2^63 and 2^64 for various uses.
enum ulong k0 = 0xc3a5c85c97cb3127UL;
enum ulong k1 = 0xb492b66fbe98f273UL;
enum ulong k2 = 0x9ae16a3b2f90404fUL;
enum ulong k3 = 0xc949d7c7509e6557UL;

struct Pair
{
    ulong first;
    ulong second;
}

ulong fetch64(scope const(ubyte)[] s, size_t i) @safe pure nothrow @nogc
{
    const ubyte[8] b = s[i .. i + 8];
    return littleEndianToNative!ulong(b);
}

ulong fetch32(scope const(ubyte)[] s, size_t i) @safe pure nothrow @nogc
{
    const ubyte[4] b = s[i .. i + 4];
    return littleEndianToNative!uint(b);
}

// Bitwise right rotate.
ulong rotate(ulong val, int shift) @safe pure nothrow @nogc
{
    // Avoid shifting by 64: doing so yields an undefined result.
    return shift == 0 ? val : ((val >> shift) | (val << (64 - shift)));
}

// Equivalent to rotate(), but requires the second arg to be non-zero.
ulong rotateByAtLeast1(ulong val, int shift) @safe pure nothrow @nogc
{
    return (val >> shift) | (val << (64 - shift));
}

ulong shiftMix(ulong val) @safe pure nothrow @nogc
{
    return val ^ (val >> 47);
}

// Hash 128 input bits down to 64 bits of output.
ulong hash128to64(ulong low, ulong high) @safe pure nothrow @nogc
{
    // Murmur-inspired hashing.
    enum ulong kMul = 0x9ddfea08eb382d69UL;
    ulong a = (low ^ high) * kMul;
    a ^= (a >> 47);
    ulong b = (high ^ a) * kMul;
    b ^= (b >> 47);
    b *= kMul;
    return b;
}

ulong hashLen16(ulong u, ulong v) @safe pure nothrow @nogc
{
    return hash128to64(u, v);
}

void swap(ref ulong a, ref ulong b) @safe pure nothrow @nogc
{
    const t = a;
    a = b;
    b = t;
}

ulong hashLen0to16(scope const(ubyte)[] s) @safe pure nothrow @nogc
{
    const len = s.length;
    if (len > 8)
    {
        const a = fetch64(s, 0);
        const b = fetch64(s, len - 8);
        return hashLen16(a, rotateByAtLeast1(b + len, cast(int) len)) ^ b;
    }
    if (len >= 4)
    {
        const a = fetch32(s, 0);
        return hashLen16(len + (a << 3), fetch32(s, len - 4));
    }
    if (len > 0)
    {
        const ubyte a = s[0];
        const ubyte b = s[len >> 1];
        const ubyte c = s[len - 1];
        const uint y = cast(uint) a + (cast(uint) b << 8);
        const uint z = cast(uint) len + (cast(uint) c << 2);
        return shiftMix(y * k2 ^ z * k3) * k2;
    }
    return k2;
}

// This probably works well for 16-byte strings as well, but it may be overkill in that case.
ulong hashLen17to32(scope const(ubyte)[] s) @safe pure nothrow @nogc
{
    const len = s.length;
    const a = fetch64(s, 0) * k1;
    const b = fetch64(s, 8);
    const c = fetch64(s, len - 8) * k2;
    const d = fetch64(s, len - 16) * k0;
    return hashLen16(rotate(a - b, 43) + rotate(c, 30) + d, a + rotate(b ^ k3, 20) - c + len);
}

// Return a 16-byte hash for 48 bytes. Quick and dirty.
// Callers do best to use "random-looking" values for a and b.
Pair weakHashLen32WithSeeds(ulong w, ulong x, ulong y, ulong z, ulong a, ulong b) @safe pure nothrow @nogc
{
    a += w;
    b = rotate(b + a + z, 21);
    const c = a;
    a += x;
    a += y;
    b += rotate(a, 44);
    return Pair(a + z, b + c);
}

// Return a 16-byte hash for s[pos] ... s[pos + 31], a, and b. Quick and dirty.
Pair weakHashLen32WithSeeds(scope const(ubyte)[] s, size_t pos, ulong a, ulong b) @safe pure nothrow @nogc
{
    return weakHashLen32WithSeeds(fetch64(s, pos), fetch64(s, pos + 8), fetch64(s, pos + 16),
            fetch64(s, pos + 24), a, b);
}

// Return an 8-byte hash for 33 to 64 bytes.
ulong hashLen33to64(scope const(ubyte)[] s) @safe pure nothrow @nogc
{
    const len = s.length;
    ulong z = fetch64(s, 24);
    ulong a = fetch64(s, 0) + (len + fetch64(s, len - 16)) * k0;
    ulong b = rotate(a + z, 52);
    ulong c = rotate(a, 37);
    a += fetch64(s, 8);
    c += rotate(a, 7);
    a += fetch64(s, 16);
    const vf = a + z;
    const vs = b + rotate(a, 31) + c;
    a = fetch64(s, 16) + fetch64(s, len - 32);
    z = fetch64(s, len - 8);
    b = rotate(a + z, 52);
    c = rotate(a, 37);
    a += fetch64(s, len - 24);
    c += rotate(a, 7);
    a += fetch64(s, len - 16);
    const wf = a + z;
    const ws = b + rotate(a, 31) + c;
    const r = shiftMix((vf + ws) * k2 + (wf + vs) * k0);
    return shiftMix(r * k0 + vs) * k2;
}

// A subroutine for cityHash128(). Returns a decent 128-bit hash for strings
// of any length representable in ssize_t. Based on City and Murmur.
UInt128 cityMurmur(scope const(ubyte)[] s, UInt128 seed) @safe pure nothrow @nogc
{
    const len = s.length;
    ulong a = seed.low;
    ulong b = seed.high;
    ulong c = 0;
    ulong d = 0;
    if (len <= 16)
    {
        a = shiftMix(a * k1) * k1;
        c = b * k1 + hashLen0to16(s);
        d = shiftMix(a + (len >= 8 ? fetch64(s, 0) : c));
    }
    else
    {
        c = hashLen16(fetch64(s, len - 8) + k1, a);
        d = hashLen16(b + len, c + fetch64(s, len - 16));
        a += d;
        size_t pos;
        ptrdiff_t l = len - 16;
        do
        {
            a ^= shiftMix(fetch64(s, pos) * k1) * k1;
            a *= k1;
            b ^= a;
            c ^= shiftMix(fetch64(s, pos + 8) * k1) * k1;
            c *= k1;
            d ^= c;
            pos += 16;
            l -= 16;
        }
        while (l > 0);
    }
    a = hashLen16(a, c);
    b = hashLen16(d, b);
    return UInt128(a ^ b, hashLen16(b, a));
}

UInt128 cityHash128WithSeed(scope const(ubyte)[] s, UInt128 seed) @safe pure nothrow @nogc
{
    if (s.length < 128)
        return cityMurmur(s, seed);

    // We expect len >= 128 to be the common case. Keep 56 bytes of state: v, w, x, y, and z.
    size_t len = s.length;
    size_t pos;
    Pair v, w;
    ulong x = seed.low;
    ulong y = seed.high;
    ulong z = len * k1;
    v.first = rotate(y ^ k1, 49) * k1 + fetch64(s, 0);
    v.second = rotate(v.first, 42) * k1 + fetch64(s, 8);
    w.first = rotate(y + z, 35) * k1 + x;
    w.second = rotate(x + fetch64(s, 88), 53) * k1;

    // This is the same inner loop as cityHash64(), manually unrolled.
    do
    {
        foreach (unroll; 0 .. 2)
        {
            x = rotate(x + y + v.first + fetch64(s, pos + 16), 37) * k1;
            y = rotate(y + v.second + fetch64(s, pos + 48), 42) * k1;
            x ^= w.second;
            y ^= v.first;
            z = rotate(z ^ w.first, 33);
            v = weakHashLen32WithSeeds(s, pos, v.second * k1, x + w.first);
            w = weakHashLen32WithSeeds(s, pos + 32, z + w.second, y);
            swap(z, x);
            pos += 64;
        }
        len -= 128;
    }
    while (len >= 128);
    y += rotate(w.first, 37) * k0 + z;
    x += rotate(v.first + z, 49) * k0;

    // If 0 < len < 128, hash up to 4 chunks of 32 bytes each from the end of s.
    for (size_t tailDone = 0; tailDone < len;)
    {
        tailDone += 32;
        y = rotate(y - x, 42) * k0 + v.second;
        w.first += fetch64(s, pos + len - tailDone + 16);
        x = rotate(x, 49) * k0 + w.first;
        w.first += v.first;
        v = weakHashLen32WithSeeds(s, pos + len - tailDone, v.first, v.second);
    }

    // At this point our 48 bytes of state should contain more than enough
    // information for a strong 128-bit hash. We use two different
    // 48-byte-to-8-byte hashes to get a 16-byte final result.
    x = hashLen16(x, v.first);
    y = hashLen16(y, w.first);
    return UInt128(hashLen16(x + v.second, w.second) + y, hashLen16(x + w.second, y + v.second));
}
