/++
ZSTD compression through the system zstd library.

Only available when the library is built with the `zstd` dub configuration,
which defines `version (ClickHousedZstd)` and links `libzstd`. Without it this
module is empty, and `clickhoused.compress.frame.zstdAvailable` is false.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.compress.zstd;

version (ClickHousedZstd)  : import clickhoused.exception : ProtocolException;

// libzstd functions, under D-style names
private extern (C) nothrow @nogc @system
{
    pragma(mangle, "ZSTD_compressBound") size_t zstdBound(size_t srcSize);
    pragma(mangle, "ZSTD_compress") size_t zstdCompressRaw(void* dst, size_t dstCapacity, const(void)* src,
            size_t srcSize, int compressionLevel);
    pragma(mangle, "ZSTD_decompress") size_t zstdDecompressRaw(void* dst, size_t dstCapacity, const(void)* src,
            size_t compressedSize);
    pragma(mangle, "ZSTD_isError") uint zstdIsError(size_t code);
    pragma(mangle, "ZSTD_getErrorName") const(char)* zstdErrorName(size_t code);
}

/// Compresses `src` into a ZSTD frame at `level` (1 is fast, up to 22).
ubyte[] zstdCompress(scope const(ubyte)[] src, int level) @trusted
{
    // The buffers passed to the C functions are D arrays of the stated sizes.
    auto dst = new ubyte[zstdBound(src.length)];
    const n = zstdCompressRaw(dst.ptr, dst.length, src.ptr, src.length, level);
    if (zstdIsError(n))
        throw new ProtocolException("ZSTD compression failed: " ~ errorName(n));
    return dst[0 .. n];
}

/++
Decompresses a ZSTD frame that expands to exactly `decompressedSize` bytes.

Throws: `ProtocolException` if the data is corrupt or has a different size.
+/
ubyte[] zstdDecompress(scope const(ubyte)[] src, size_t decompressedSize) @trusted
{
    // The buffers passed to the C functions are D arrays of the stated sizes.
    auto dst = new ubyte[decompressedSize];
    const n = zstdDecompressRaw(dst.ptr, dst.length, src.ptr, src.length);
    if (zstdIsError(n))
        throw new ProtocolException("ZSTD decompression failed: " ~ errorName(n));
    if (n != decompressedSize)
        throw new ProtocolException("ZSTD block has a wrong decompressed size");
    return dst;
}

///
@safe unittest
{
    auto data = cast(const(ubyte)[]) "zstd zstd zstd zstd zstd zstd zstd zstd zstd zstd zstd";
    auto compressed = zstdCompress(data, 1);
    assert(zstdDecompress(compressed, data.length) == data);
}

@safe unittest
{
    import std.exception : assertThrown;

    assertThrown!ProtocolException(zstdDecompress([1, 2, 3, 4], 10));
    auto compressed = zstdCompress(new ubyte[100], 3);
    assertThrown!ProtocolException(zstdDecompress(compressed, 99));
}

private string errorName(size_t code) @trusted nothrow
{
    import std.string : fromStringz;

    return zstdErrorName(code).fromStringz.idup; // ZSTD returns a static C string
}
