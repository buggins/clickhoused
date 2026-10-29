/++
ClickHouse compressed blocks ("frames") and the streams that read and write them.

With network compression enabled, the data part of each Data packet is sent
as one or more frames:
$(UL
    $(LI 16 bytes: CityHash128 v1.0.2 checksum of the rest of the frame (low 64 bits first, little-endian);)
    $(LI 1 byte: method: `0x02` none, `0x82` LZ4, `0x90` ZSTD;)
    $(LI 4 bytes: compressed size, including this 9-byte header;)
    $(LI 4 bytes: decompressed size;)
    $(LI the compressed data.)
)

`CompressedInput` and `CompressedOutput` are `Transport`s, so the usual
`BufferedReader` and `BufferedWriter` work on top of them.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.compress.frame;

import core.time : Duration;

import clickhoused.compress.cityhash : UInt128, cityHash128;
import clickhoused.compress.lz4 : lz4Compress, lz4Decompress;
import clickhoused.exception : ClientException, ProtocolException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter, fromLittleEndian, toLittleEndian;
import clickhoused.io.transport : Transport;

version (ClickHousedZstd) import clickhoused.compress.zstd : zstdCompress, zstdDecompress;

/// Network compression method of a connection.
enum Compression
{
    /// No compression.
    none,
    /// LZ4: fast, moderate ratio. A good default for remote servers.
    lz4,
    /// ZSTD: better ratio, more CPU. Needs the `zstd` dub configuration.
    zstd,
}

version (ClickHousedZstd)
    private enum bool hasZstd = true;
else
    private enum bool hasZstd = false;

/// Whether ZSTD support is compiled in (the `zstd` dub configuration).
enum bool zstdAvailable = hasZstd;

/// Frames and decompressed data larger than this (1 GiB) are rejected, as the server does.
enum size_t maxFrameSize = 0x4000_0000;

/++
Encodes `data` as one frame.

Params:
    data = data to compress.
    method = compression method; `Compression.none` stores the data as is.
    zstdLevel = ZSTD compression level.

Throws: `ClientException` if ZSTD is requested but not compiled in.
+/
ubyte[] encodeFrame(scope const(ubyte)[] data, Compression method, int zstdLevel = 1) @safe
{
    const(ubyte)[] payload;
    ubyte methodByte;
    final switch (method)
    {
    case Compression.none:
        payload = data;
        methodByte = methodNone;
        break;
    case Compression.lz4:
        payload = lz4Compress(data);
        methodByte = methodLz4;
        break;
    case Compression.zstd:
        version (ClickHousedZstd)
            payload = zstdCompress(data, zstdLevel);
        else
            throw zstdNotAvailable();
        methodByte = methodZstd;
        break;
    }
    auto frame = new ubyte[checksumSize + headerSize + payload.length];
    frame[checksumSize] = methodByte;
    frame[checksumSize + 1 .. checksumSize + 5] = toLittleEndian(cast(uint)(headerSize + payload.length));
    frame[checksumSize + 5 .. checksumSize + 9] = toLittleEndian(cast(uint) data.length);
    frame[checksumSize + headerSize .. $] = payload[];
    const checksum = cityHash128(frame[checksumSize .. $]);
    frame[0 .. 8] = toLittleEndian(checksum.low);
    frame[8 .. 16] = toLittleEndian(checksum.high);
    return frame;
}

/++
Reads one frame from `reader` and returns the decompressed data.

Throws: `ProtocolException` on a bad checksum, size or method;
`clickhoused.exception.ConnectionException` if the stream ends.
+/
ubyte[] readFrame(BufferedReader reader) @safe
{
    ubyte[checksumSize + headerSize] head;
    reader.readExact(head[]);
    const expected = UInt128(fromLittleEndian!ulong(head[0 .. 8]), fromLittleEndian!ulong(head[8 .. 16]));
    const methodByte = head[checksumSize];
    const compressedSize = fromLittleEndian!uint(head[checksumSize + 1 .. checksumSize + 5]);
    const decompressedSize = fromLittleEndian!uint(head[checksumSize + 5 .. checksumSize + 9]);
    if (compressedSize < headerSize || compressedSize > maxFrameSize || decompressedSize > maxFrameSize)
        throw new ProtocolException("Invalid compressed block sizes");

    auto frame = new ubyte[compressedSize];
    frame[0 .. headerSize] = head[checksumSize .. $];
    reader.readExact(frame[headerSize .. $]);
    if (cityHash128(frame) != expected)
        throw new ProtocolException("Compressed block checksum mismatch: corrupted data");

    const payload = frame[headerSize .. $];
    switch (methodByte)
    {
    case methodNone:
        if (payload.length != decompressedSize)
            throw new ProtocolException("Uncompressed block has a wrong size");
        return frame[headerSize .. $];
    case methodLz4:
        return lz4Decompress(payload, decompressedSize);
    case methodZstd:
        version (ClickHousedZstd)
            return zstdDecompress(payload, decompressedSize);
        else
            throw new ProtocolException("The server sent ZSTD-compressed data, but ZSTD support is not compiled in");
    default:
        throw new ProtocolException("Unsupported compression method in a compressed block");
    }
}

///
@safe unittest
{
    import clickhoused.io.mock : MockTransport;

    auto data = cast(const(ubyte)[]) "a block of data, a block of data, a block of data";
    auto t = new MockTransport;
    t.feed(encodeFrame(data, Compression.lz4));
    assert(readFrame(new BufferedReader(t)) == data);
}

/++
Reading side of a compressed stream: decompresses frames from `source` and
returns their contents. Read-only.
+/
final class CompressedInput : Transport
{
    private BufferedReader source;
    private ubyte[] frame;
    private size_t pos;

    /// Creates a stream that reads frames from `source`.
    this(BufferedReader source) @safe
    {
        this.source = source;
    }

    /// Whether the current frame has been fully consumed. Each compressed
    /// block of the protocol ends at a frame boundary.
    @property bool atFrameBoundary() const @safe pure nothrow
    {
        return pos == frame.length;
    }

    override size_t read(ubyte[] buffer) @safe
    {
        while (pos == frame.length)
        {
            frame = readFrame(source);
            pos = 0;
        }
        const n = buffer.length < frame.length - pos ? buffer.length : frame.length - pos;
        buffer[0 .. n] = frame[pos .. pos + n];
        pos += n;
        return n;
    }

    override void write(const(ubyte)[] data) @safe
    {
        throw new ClientException("CompressedInput is read-only");
    }

    override bool dataAvailable() @safe
    {
        return pos < frame.length;
    }

    override void close() @safe nothrow
    {
    }

    override bool connected() const @safe nothrow
    {
        return true;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
    }
}

/++
Writing side of a compressed stream: each `write` becomes one frame, appended
to `target` (which the caller flushes). Use it under a `BufferedWriter`, whose
buffer size then sets the frame size.
+/
final class CompressedOutput : Transport
{
    private BufferedWriter target;
    private Compression method;
    private int zstdLevel;

    /++
    Creates a stream that writes frames to `target`.

    Params:
        target = destination of the frames.
        method = compression method.
        zstdLevel = ZSTD compression level.
    +/
    this(BufferedWriter target, Compression method, int zstdLevel = 1) @safe
    {
        if (method == Compression.zstd && !zstdAvailable)
            throw zstdNotAvailable();
        this.target = target;
        this.method = method;
        this.zstdLevel = zstdLevel;
    }

    override size_t read(ubyte[] buffer) @safe
    {
        throw new ClientException("CompressedOutput is write-only");
    }

    override void write(const(ubyte)[] data) @safe
    {
        if (data.length)
            target.writeBytes(encodeFrame(data, method, zstdLevel));
    }

    override bool dataAvailable() @safe
    {
        return false;
    }

    override void close() @safe nothrow
    {
    }

    override bool connected() const @safe nothrow
    {
        return true;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
    }
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.io.mock : MockTransport;

    // A stream written through CompressedOutput reads back through CompressedInput,
    // across several frames, with every supported method
    auto payload = new ubyte[200_000];
    foreach (i, ref b; payload)
        b = cast(ubyte)(i % 251);
    Compression[] methods = [Compression.none, Compression.lz4];
    if (zstdAvailable)
        methods ~= Compression.zstd;
    foreach (method; methods)
    {
        auto wire = new MockTransport;
        auto raw = new BufferedWriter(wire);
        auto writer = new BufferedWriter(new CompressedOutput(raw, method), 64 * 1024);
        writer.writeBytes(payload);
        writer.writeString("end");
        writer.flush();
        raw.flush();
        if (method != Compression.none)
            assert(wire.written.length < payload.length / 2);

        wire.feed(wire.written);
        auto input = new CompressedInput(new BufferedReader(wire));
        auto reader = new BufferedReader(input);
        auto back = new ubyte[payload.length];
        reader.readExact(back);
        assert(back == payload && reader.readString() == "end");
        assert(input.atFrameBoundary && reader.buffered == 0 && wire.remaining == 0);
    }

    // Corruption is detected by the checksum
    auto frame = encodeFrame(payload[0 .. 1000], Compression.lz4);
    frame[$ - 1] ^= 1;
    auto t = new MockTransport;
    t.feed(frame);
    assertThrown!ProtocolException(readFrame(new BufferedReader(t)));

    static if (!zstdAvailable)
        assertThrown!ClientException(encodeFrame(payload, Compression.zstd));
}

@safe unittest
{
    import std.conv : hexString;
    import clickhoused.io.mock : MockTransport;

    // A complete block written by `clickhouse compressor` (checksum, header, LZ4 data)
    enum block = cast(immutable(ubyte)[]) hexString!(
                "bba0e6512c7fb7ad33dc17eeb9cc864f823100000050010000ff0d436c69636b486f757365206e61746976652070726f746f63"
                ~ "6f6c2c201c00ff1d50636f6c2c20");
    auto t = new MockTransport;
    t.feed(block);
    string expected;
    foreach (i; 0 .. 12)
        expected ~= "ClickHouse native protocol, ";
    assert(readFrame(new BufferedReader(t)) == cast(const(ubyte)[]) expected);
}

private enum size_t checksumSize = 16;
private enum size_t headerSize = 9;
private enum ubyte methodNone = 0x02;
private enum ubyte methodLz4 = 0x82;
private enum ubyte methodZstd = 0x90;

private ClientException zstdNotAvailable() @safe pure nothrow
{
    return new ClientException("ZSTD compression is not compiled in: build clickhoused with the 'zstd' "
            ~ "configuration, or use Compression.lz4");
}
