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
    auto dst = new ubyte[lz4CompressBound(src.length)];
    size_t op;
    size_t anchor;

    if (src.length > mfLimit)
    {
        uint[1 << hashLog] table; // position + 1 of the last occurrence of each hash; 0 = none
        const matchLimit = src.length - lastLiterals;
        size_t ip;
        uint misses;
        while (ip + mfLimit < src.length)
        {
            const sequence = read32(src, ip);
            const h = hash(sequence);
            const candidate = table[h];
            table[h] = cast(uint)(ip + 1);
            if (candidate != 0)
            {
                size_t from = candidate - 1;
                if (ip - from <= maxOffset && read32(src, from) == sequence)
                {
                    size_t start = ip;
                    size_t length = minMatch;
                    while (start + length < matchLimit && src[from + length] == src[start + length])
                        length++;
                    while (start > anchor && from > 0 && src[start - 1] == src[from - 1])
                    {
                        start--;
                        from--;
                        length++;
                    }
                    op = writeSequence(dst, op, src[anchor .. start], start - from, length);
                    ip = start + length;
                    anchor = ip;
                    misses = 0;
                    continue;
                }
            }
            ip += 1 + (misses++ >> 6); // skip faster through incompressible data
        }
    }
    op = writeLastLiterals(dst, op, src[anchor .. $]);
    return dst[0 .. op];
}

/++
Decompresses an LZ4 block that expands to exactly `decompressedSize` bytes.

Throws: `ProtocolException` if the block is malformed or does not expand to
`decompressedSize` bytes.
+/
ubyte[] lz4Decompress(scope const(ubyte)[] src, size_t decompressedSize) @safe pure
{
    auto dst = new ubyte[decompressedSize];
    size_t ip;
    size_t op;
    for (;;)
    {
        if (ip >= src.length)
            throw corrupt();
        const token = src[ip++];

        size_t literals = token >> 4;
        if (literals == 15)
            literals += readLength(src, ip);
        if (literals > src.length - ip || literals > dst.length - op)
            throw corrupt();
        dst[op .. op + literals] = src[ip .. ip + literals];
        ip += literals;
        op += literals;
        if (ip == src.length)
            break; // the last sequence has no match

        if (src.length - ip < 2)
            throw corrupt();
        const offset = src[ip] | (src[ip + 1] << 8);
        ip += 2;
        if (offset == 0 || offset > op)
            throw corrupt();
        size_t length = (token & 0x0F) + minMatch;
        if ((token & 0x0F) == 15)
            length += readLength(src, ip);
        if (length > dst.length - op)
            throw corrupt();
        const from = op - offset;
        if (offset >= length)
            dst[op .. op + length] = dst[from .. from + length];
        else
        {
            // Overlapping copy: repeats the last `offset` bytes
            foreach (i; 0 .. length)
                dst[op + i] = dst[from + i];
        }
        op += length;
    }
    if (op != dst.length)
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

uint read32(scope const(ubyte)[] s, size_t i) @safe pure nothrow @nogc
{
    return s[i] | (s[i + 1] << 8) | (s[i + 2] << 16) | (cast(uint) s[i + 3] << 24);
}

uint hash(uint sequence) @safe pure nothrow @nogc
{
    return (sequence * 2_654_435_761U) >> (32 - hashLog);
}

size_t writeLength(ubyte[] dst, size_t op, size_t value) @safe pure nothrow @nogc
{
    while (value >= 255)
    {
        dst[op++] = 255;
        value -= 255;
    }
    dst[op++] = cast(ubyte) value;
    return op;
}

size_t writeSequence(ubyte[] dst, size_t op, scope const(ubyte)[] literals, size_t offset,
        size_t matchLength) @safe pure nothrow @nogc
{
    const matchCode = matchLength - minMatch;
    const count = literals.length;
    dst[op++] = cast(ubyte)((count < 15 ? count : 15) << 4 | (matchCode < 15 ? matchCode : 15));
    if (count >= 15)
        op = writeLength(dst, op, count - 15);
    dst[op .. op + literals.length] = literals[];
    op += literals.length;
    dst[op++] = cast(ubyte) offset;
    dst[op++] = cast(ubyte)(offset >> 8);
    if (matchCode >= 15)
        op = writeLength(dst, op, matchCode - 15);
    return op;
}

size_t writeLastLiterals(ubyte[] dst, size_t op, scope const(ubyte)[] literals) @safe pure nothrow @nogc
{
    const count = literals.length;
    dst[op++] = cast(ubyte)((count < 15 ? count : 15) << 4);
    if (count >= 15)
        op = writeLength(dst, op, count - 15);
    dst[op .. op + literals.length] = literals[];
    return op + literals.length;
}

/// Reads the extra length bytes that follow a length code of 15.
size_t readLength(scope const(ubyte)[] src, ref size_t ip) @safe pure
{
    size_t total;
    ubyte b;
    do
    {
        if (ip >= src.length)
            throw corrupt();
        b = src[ip++];
        total += b;
    }
    while (b == 255);
    return total;
}

ProtocolException corrupt() @safe pure nothrow
{
    return new ProtocolException("Corrupted LZ4 block");
}
