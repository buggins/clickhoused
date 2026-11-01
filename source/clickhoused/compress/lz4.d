/++
LZ4 block compression and decompression, written from the LZ4 block format
specification.

A block is a series of sequences. Each sequence is a token byte (high 4 bits:
literal count, low 4 bits: match length minus 4; the value 15 means more
length bytes follow, each adding up to 255), the literal bytes, a 2-byte
little-endian match offset, and the extra match length bytes. The last
sequence has literals only. The last 5 bytes of a block are always literals,
and the last match starts at least 12 bytes before the end.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.compress.lz4;

import clickhoused.exception : ProtocolException;

/// Maximum compressed size of `inputSize` bytes of input.
size_t lz4CompressBound(size_t inputSize) @safe pure nothrow @nogc
{
    return inputSize + inputSize / 255 + 16;
}

/// Compresses `src` into an LZ4 block.
ubyte[] lz4Compress(scope const(ubyte)[] src) @safe pure nothrow
{
    import std.array : uninitializedArray;

    auto dst = uninitializedArray!(ubyte[])(lz4CompressBound(src.length));
    return dst[0 .. compressBlock(src, dst)];
}

/++
Decompresses an LZ4 block that expands to exactly `decompressedSize` bytes.

Throws: `ProtocolException` if the block is malformed or does not expand to
`decompressedSize` bytes.
+/
ubyte[] lz4Decompress(scope const(ubyte)[] src, size_t decompressedSize) @safe pure
{
    import std.array : uninitializedArray;

    auto dst = uninitializedArray!(ubyte[])(decompressedSize);
    if (!decompressBlock(src, dst))
        throw corrupt();
    return dst;
}

///
@safe pure unittest
{
    auto text = cast(const(ubyte)[]) "abcabcabcabcabcabcabcabcabcabcabcabc, and some more text at the end";
    auto compressed = lz4Compress(text);
    assert(compressed.length < text.length);
    assert(lz4Decompress(compressed, text.length) == text);
}

@safe pure unittest
{
    import std.conv : hexString;

    // LZ4 payloads from blocks written by `clickhouse compressor` (ClickHouse's own encoder)
    enum textBlock = cast(immutable(ubyte)[]) hexString!(
                "ff0d436c69636b486f757365206e61746976652070726f746f636f6c2c201c00ff1d50636f6c2c20");
    string expected;
    foreach (i; 0 .. 12)
        expected ~= "ClickHouse native protocol, ";
    assert(lz4Decompress(textBlock, expected.length) == cast(const(ubyte)[]) expected);

    enum patternBlock = cast(immutable(ubyte)[]) hexString!(
                "fff1030b15212f3f51657b93adc9e707294d739bc5f11f4f81b5eb235d99d717599de32b75c10f5fb1055bb30d69c727"
                ~ "89ed53bb2591ff6fe155cb43bd39b737b93dc34bd561ef7f11a53bd36d09a747e98d33db8531df8f41f5ab631dd99757"
                ~ "19dda36b3501cf9f71451bf3cda98767492d13fbe5d1bfafa1958b837d797777797d838b95a1afbfd1e5fb132d496787"
                ~ "a9cdf31b45719fcf01356ba3dd195797d91d63abf5418fdf3185db338de947a7096dd33ba5117fef61d54bc33db937b7"
                ~ "39bd43cb55e16fff9125bb53ed8927c7690db35b05b15f0fc1752be39d5917d7995d23ebb5814f1ff1c59b734d2907e7"
                ~ "c9ad937b65513f2f21150b03fdf9f7f7f9fd00011450055bb30d69");
    auto pattern = new ubyte[300];
    foreach (i, ref b; pattern)
        b = cast(ubyte)(i * i + 7 * i + 3);
    assert(lz4Decompress(patternBlock, 300) == pattern);
}

@safe pure unittest
{
    // Round trips: empty, tiny, long runs, overlapping matches, incompressible data, long literal runs
    const ubyte[] tiny = [1];
    const ubyte[] thirteen = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13];
    const(ubyte)[][] inputs = [null, tiny, thirteen];
    inputs ~= new ubyte[100_000]; // zeros: one huge overlapping match
    auto noise = new ubyte[70_000];
    uint state = 12_345;
    foreach (ref b; noise)
    {
        state = state * 1_103_515_245 + 12_345;
        b = cast(ubyte)(state >> 16);
    }
    inputs ~= noise;
    auto mixed = noise[0 .. 1000] ~ noise[0 .. 1000] ~ new ubyte[300] ~ noise[500 .. 600];
    inputs ~= mixed;
    foreach (n; 0 .. 40)
        inputs ~= noise[0 .. n] ~ noise[0 .. n];
    foreach (input; inputs)
    {
        auto compressed = lz4Compress(input);
        assert(compressed.length <= lz4CompressBound(input.length));
        assert(lz4Decompress(compressed, input.length) == input);
    }
    assert(lz4Compress(new ubyte[100_000]).length < 500);
}

@safe pure unittest
{
    // Repeats at every short distance and length, also close to the end of the output, where the decoder
    // switches from 8-byte copies to exact ones
    foreach (period; 1 .. 17)
        foreach (length; [4, 5, 7, 8, 9, 15, 16, 17, 19, 31, 64, 300])
            foreach (tail; [5, 6, 8, 12, 13, 20, 40])
            {
                ubyte[] input;
                foreach (i; 0 .. period)
                    input ~= cast(ubyte)(i * 37 + 11);
                foreach (i; 0 .. length)
                    input ~= input[$ - period];
                foreach (i; 0 .. tail)
                    input ~= cast(ubyte)(i * 91 + 5);
                assert(lz4Decompress(lz4Compress(input), input.length) == input);
            }

    // Hand-made blocks: "abc", a match at distance 3 of length 16, then 5 literals; and a block with extra
    // length bytes (literal count 15 + 0, match length 4 + 15 + 1)
    const ubyte[] block = [0x3C, 'a', 'b', 'c', 0x03, 0x00, 0x50, 'v', 'w', 'x', 'y', 'z'];
    assert(lz4Decompress(block, 3 + 16 + 5) == cast(const(ubyte)[]) "abcabcabcabcabcabcavwxyz");
    const ubyte[] longCodes = [
        0xFF, 0, 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '0', '1', '2', '3', 0x01, 0x00,
        1, 0x50,
        'a', 'b', 'c', 'd', 'e'
    ];
    assert(lz4Decompress(longCodes, 15 + 20 + 5) == cast(const(ubyte)[]) "pqrstuvwxyz012333333333333333333333abcde");
}

@safe pure unittest
{
    import std.exception : assertThrown;

    // Malformed blocks are rejected, never read or written out of bounds
    assertThrown!ProtocolException(lz4Decompress([], 0));
    assertThrown!ProtocolException(lz4Decompress([0x10], 1)); // literal missing
    assertThrown!ProtocolException(lz4Decompress([0x10, 'a'], 2)); // too short
    assertThrown!ProtocolException(lz4Decompress([0x10, 'a', 0x00, 0x00], 10)); // offset 0
    assertThrown!ProtocolException(lz4Decompress([0x10, 'a', 0x05, 0x00], 10)); // offset beyond output
    assertThrown!ProtocolException(lz4Decompress([0xF0, 0xFF, 0xFF], 10)); // length runs past the input

    // Random garbage must fail cleanly or decode to the requested size
    uint state = 1;
    foreach (round; 0 .. 2000)
    {
        auto junk = new ubyte[round % 64 + 1];
        foreach (ref b; junk)
        {
            state = state * 1_103_515_245 + 12_345;
            b = cast(ubyte)(state >> 16);
        }
        try
            assert(lz4Decompress(junk, round % 200).length == round % 200);
        catch (ProtocolException)
        {
        }
    }
}

private:

enum size_t minMatch = 4;
enum size_t mfLimit = 12; // the last match starts at least this far before the end
enum size_t lastLiterals = 5; // the last bytes are always literals
enum size_t maxOffset = 65_535;
enum uint hashLog = 12;

/++
Compresses `src` into `dst` (at least `lz4CompressBound(src.length)` bytes) and
returns the compressed size.

Pointer code, for speed: reads stay within `src` (the match search stops
`mfLimit` bytes before its end, 8-byte reads `lastLiterals` before it), and
`dst` is large enough for the worst case.
+/
size_t compressBlock(scope const(ubyte)[] src, scope ubyte[] dst) @trusted pure nothrow @nogc
{
    assert(dst.length >= lz4CompressBound(src.length));
    const(ubyte)* base = src.ptr;
    const(ubyte)* anchor = base;
    ubyte* op = dst.ptr;
    if (src.length > mfLimit)
    {
        uint[1 << hashLog] table = 0; // position + 1 of the last occurrence of each hash; 0 = none
        const(ubyte)* ip = base;
        const(ubyte)* searchEnd = base + src.length - mfLimit; // a match starts before this
        const(ubyte)* matchLimit = base + src.length - lastLiterals; // and ends before this
        uint misses;
        while (ip < searchEnd)
        {
            const sequence = load32(ip);
            const h = hash(sequence);
            const candidate = table[h];
            table[h] = cast(uint)(ip - base + 1);
            if (candidate != 0)
            {
                const(ubyte)* from = base + (candidate - 1);
                if (ip - from <= maxOffset && load32(from) == sequence)
                {
                    const(ubyte)* end = extendMatch(ip + minMatch, from + minMatch, matchLimit);
                    const(ubyte)* start = ip;
                    while (start > anchor && from > base && start[-1] == from[-1])
                    {
                        start--;
                        from--;
                    }
                    op = writeSequence(op, anchor, start - anchor, start - from, end - start);
                    ip = end;
                    anchor = ip;
                    misses = 0;
                    continue;
                }
            }
            ip += 1 + (misses++ >> 6); // skip faster through incompressible data
        }
    }
    op = writeLiterals(op, anchor, base + src.length - anchor, true);
    return op - dst.ptr;
}

/++
The end of the match that continues at `s` with the earlier bytes at `m`,
stopping at `limit`. Compares 8 bytes at a time.
+/
const(ubyte)* extendMatch(const(ubyte)* s, const(ubyte)* m, const(ubyte)* limit) @system pure nothrow @nogc
{
    version (LittleEndian)
    {
        import core.bitop : bsf;

        while (limit - s >= 8)
        {
            const diff = load64(s) ^ load64(m);
            if (diff != 0)
                return s + (bsf(diff) >> 3); // the first differing byte
            s += 8;
            m += 8;
        }
    }
    while (s < limit && *s == *m)
    {
        s++;
        m++;
    }
    return s;
}

/// Writes a sequence: token, literals, offset and match length.
ubyte* writeSequence(ubyte* op, const(ubyte)* literals, size_t count, size_t offset, size_t matchLength) @system pure
nothrow @nogc
{
    const matchCode = matchLength - minMatch;
    op = writeLiterals(op, literals, count, false, matchCode < 15 ? matchCode : 15);
    *op++ = cast(ubyte) offset;
    *op++ = cast(ubyte)(offset >> 8);
    if (matchCode >= 15)
        op = writeLength(op, matchCode - 15);
    return op;
}

/// Writes a token (with `matchCode` in the low bits) and `count` literals.
ubyte* writeLiterals(ubyte* op, const(ubyte)* literals, size_t count, bool last, size_t matchCode = 0) @system pure
nothrow @nogc
{
    import core.stdc.string : memcpy;

    *op++ = cast(ubyte)((count < 15 ? count : 15) << 4 | (last ? 0 : matchCode));
    if (count >= 15)
        op = writeLength(op, count - 15);
    memcpy(op, literals, count);
    return op + count;
}

/// Writes the extra bytes of a length above 14.
ubyte* writeLength(ubyte* op, size_t value) @system pure nothrow @nogc
{
    while (value >= 255)
    {
        *op++ = 255;
        value -= 255;
    }
    *op++ = cast(ubyte) value;
    return op;
}

/++
Decodes the block `src` into `dst`, which it must fill exactly. Returns false
if the block is malformed.

Pointer code, for speed. Every length is checked against the ends of both
buffers before it is used; copies of a fixed 8 or 16 bytes, which may run past
the end of a literal run or match, are used only where at least that much room
is left.
+/
bool decompressBlock(scope const(ubyte)[] src, scope ubyte[] dst) @trusted pure nothrow @nogc
{
    import core.stdc.string : memcpy;

    if (src.length == 0)
        return false;
    const(ubyte)* ip = src.ptr;
    const(ubyte)* iend = ip + src.length;
    const start = dst.ptr;
    ubyte* op = dst.ptr;
    const oend = start + dst.length;
    for (;;)
    {
        if (ip >= iend)
            return false;
        const token = *ip++;

        size_t literals = token >> 4;
        if (literals == 15 && !addLength(ip, iend, literals))
            return false;
        if (literals <= 16 && iend - ip >= 16 && oend - op >= 16)
            memcpy(op, ip, 16); // the common short run: one fixed-size copy
        else if (literals <= cast(size_t)(iend - ip) && literals <= cast(size_t)(oend - op))
            memcpy(op, ip, literals);
        else
            return false;
        ip += literals;
        op += literals;
        if (ip == iend)
            break; // the last sequence has no match

        if (iend - ip < 2)
            return false;
        const offset = ip[0] | (ip[1] << 8);
        ip += 2;
        if (offset == 0 || offset > op - start)
            return false;
        size_t length = (token & 0x0F) + minMatch;
        if ((token & 0x0F) == 15 && !addLength(ip, iend, length))
            return false;
        if (length > cast(size_t)(oend - op))
            return false;

        const(ubyte)* from = op - offset;
        const end = op + length;
        if (cast(size_t)(oend - op) >= length + 8)
        {
            if (offset < 8)
            {
                // A short repeat: extend it byte by byte until it can be read from a multiple of `offset`
                // at least 8 bytes back, then copy 8 bytes at a time from there
                const period = offset * ((8 + offset - 1) / offset);
                size_t first = period - offset;
                if (first > length)
                    first = length;
                foreach (i; 0 .. first)
                    op[i] = from[i];
                op += first;
                if (op < end)
                    from = op - period; // at or after `start`: `first` = `period - offset` here
            }
            while (op < end)
            {
                memcpy(op, from, 8); // the source ends at or before `op`
                op += 8;
                from += 8;
            }
        }
        else
        {
            foreach (i; 0 .. length) // near the end of the output: exact copy
                op[i] = from[i];
        }
        op = dst.ptr + (end - start);
    }
    return op == oend;
}

/// Adds the extra length bytes that follow a length code of 15 to `total`; false if they run past `iend`.
bool addLength(ref const(ubyte)* ip, const(ubyte)* iend, ref size_t total) @system pure nothrow @nogc
{
    ubyte b;
    do
    {
        if (ip >= iend)
            return false;
        b = *ip++;
        total += b;
    }
    while (b == 255);
    return true;
}

/// Reads 4 bytes, little-endian, at any alignment.
uint load32(const(ubyte)* p) @system pure nothrow @nogc
{
    import core.stdc.string : memcpy;

    uint v = void;
    memcpy(&v, p, 4);
    version (BigEndian)
    {
        import core.bitop : bswap;

        v = bswap(v);
    }
    return v;
}

/// Reads 8 bytes in memory order, at any alignment.
ulong load64(const(ubyte)* p) @system pure nothrow @nogc
{
    import core.stdc.string : memcpy;

    ulong v = void;
    memcpy(&v, p, 8);
    return v;
}

uint hash(uint sequence) @safe pure nothrow @nogc
{
    return (sequence * 2_654_435_761U) >> (32 - hashLog);
}

ProtocolException corrupt() @safe pure nothrow
{
    return new ProtocolException("Corrupted LZ4 block");
}
