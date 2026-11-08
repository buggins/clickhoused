/++
ZSTD compression through the system zstd library.

Only available when the library is built with the `zstd` dub configuration,
which defines `version (ClickHousedZstd)` and links `libzstd`. Without it this
module is empty, and `clickhoused.compress.frame.zstdAvailable` is false.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.compress.zstd;

version (ClickHousedZstd)  : import clickhoused.exception : ClientException, ProtocolException;

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

/++
Compresses `src` into a ZSTD frame at `level` (1 is fast, up to 22).

Throws: `ClientException` if libzstd fails.
+/
ubyte[] zstdCompress(scope const(ubyte)[] src, int level) @safe
{
    auto dst = new ubyte[(() @trusted => zstdBound(src.length))()]; // a pure size computation
    // ZSTD_compress writes at most dst.length bytes and reads src.length bytes
    const n = (() @trusted => zstdCompressRaw(dst.ptr, dst.length, src.ptr, src.length, level))();
    if ((()@trusted => zstdIsError(n))())
        throw new ClientException("ZSTD compression failed: " ~ errorName(n)); // a local failure, not the server's
    return dst[0 .. n];
}

/++
Decompresses a ZSTD frame that expands to exactly `decompressedSize` bytes.

Throws: `ProtocolException` if the data is corrupt or has a different size.
+/
ubyte[] zstdDecompress(scope const(ubyte)[] src, size_t decompressedSize) @safe
{
    auto dst = new ubyte[decompressedSize];
    // ZSTD_decompress writes at most dst.length bytes and reads src.length bytes
    const n = (() @trusted => zstdDecompressRaw(dst.ptr, dst.length, src.ptr, src.length))();
    if ((()@trusted => zstdIsError(n))())
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
