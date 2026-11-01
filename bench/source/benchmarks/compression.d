/++
Compression benchmarks: LZ4 alone, compressed frames (with their CityHash
checksum), CityHash128 alone, and decoding blocks through a compressed stream,
as `Connection` does with `compression` on.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module benchmarks.compression;

import clickhoused;
import clickhoused.block : readBlock, writeBlock;
import clickhoused.compress.cityhash : cityHash128;
import clickhoused.compress.frame : CompressedInput, CompressedOutput, Compression, encodeFrame, readFrame,
    zstdAvailable;
import clickhoused.compress.lz4 : lz4Compress, lz4Decompress;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.protocol.codes : Revision;

import benchmarks.offline : encode, makeBlocks, MemoryTransport, mixedSpecs, RecordingTransport;
import benchmarks.runner : BenchCase, Prepared;

/// Size of the chunks compressed separately (ClickHouse's default `max_compress_block_size`).
enum chunkSize = 1 << 20;

/// Wire bytes of blocks of mixed columns: a realistic payload to compress.
private immutable(ubyte)[] payload(size_t rows)
{
    return encode(makeBlocks(mixedSpecs(6), rows));
}

/// `data` cut into chunks of `chunkSize`.
private const(ubyte)[][] chunks(const(ubyte)[] data)
{
    const(ubyte)[][] parts;
    for (size_t i = 0; i < data.length; i += chunkSize)
        parts ~= data[i .. i + chunkSize < data.length ? i + chunkSize : data.length];
    return parts;
}

/// The compression cases. `rows` is the number of rows of the payload.
BenchCase[] compressionCases()
{
    BenchCase[] cases;

    Prepared lz4CompressCase(size_t rows)
    {
        auto parts = chunks(payload(rows));
        size_t bytes;
        foreach (p; parts)
            bytes += p.length;
        void run()
        {
            foreach (p; parts)
                cast(void) lz4Compress(p);
        }

        return Prepared(rows, bytes, &run);
    }

    Prepared lz4DecompressCase(size_t rows)
    {
        auto parts = chunks(payload(rows));
        ubyte[][] compressed;
        size_t bytes;
        foreach (p; parts)
        {
            compressed ~= lz4Compress(p);
            bytes += p.length;
        }
        void run()
        {
            foreach (i, c; compressed)
                cast(void) lz4Decompress(c, parts[i].length);
        }

        return Prepared(rows, bytes, &run);
    }

    Prepared cityHashCase(size_t rows)
    {
        auto data = payload(rows);
        void run()
        {
            foreach (p; chunks(data))
                cast(void) cityHash128(p);
        }

        return Prepared(rows, data.length, &run);
    }

    Prepared delegate(size_t) frameEncode(Compression method)
    {
        Prepared prepare(size_t rows)
        {
            auto parts = chunks(payload(rows));
            size_t bytes;
            foreach (p; parts)
                bytes += p.length;
            void run()
            {
                foreach (p; parts)
                    cast(void) encodeFrame(p, method);
            }

            return Prepared(rows, bytes, &run);
        }

        return &prepare;
    }

    Prepared delegate(size_t) frameDecode(Compression method)
    {
        Prepared prepare(size_t rows)
        {
            const data = payload(rows);
            ubyte[] frames;
            foreach (p; chunks(data))
                frames ~= encodeFrame(p, method);
            auto transport = new MemoryTransport(frames.idup);
            const count = chunks(data).length;
            void run()
            {
                transport.reset();
                auto reader = new BufferedReader(transport);
                foreach (_; 0 .. count)
                    cast(void) readFrame(reader);
            }

            return Prepared(rows, data.length, &run);
        }

        return &prepare;
    }

    // Blocks through a compressed stream, one frame per block as the server sends them
    Prepared delegate(size_t) decodeCompressed(Compression method)
    {
        Prepared prepare(size_t rows)
        {
            auto blocks = makeBlocks(mixedSpecs(6), rows);
            auto recording = new RecordingTransport;
            auto plain = new BufferedWriter(recording);
            auto blockWriter = new BufferedWriter(new CompressedOutput(plain, method), 1 << 20);
            foreach (b; blocks)
            {
                writeBlock(blockWriter, b, Revision.client);
                blockWriter.flush();
            }
            plain.flush();
            auto transport = new MemoryTransport(recording.data.idup);
            const wireBytes = encode(blocks).length;
            void run()
            {
                transport.reset();
                auto reader = new BufferedReader(new CompressedInput(new BufferedReader(transport)));
                size_t read;
                while (read < rows)
                    read += readBlock(reader, Revision.client, "UTC").rows;
            }

            return Prepared(rows, wireBytes, &run);
        }

        return &prepare;
    }

    enum rows = 1_000_000;
    cases ~= BenchCase("lz4/compress 1 MiB chunks", &lz4CompressCase, rows);
    cases ~= BenchCase("lz4/decompress 1 MiB chunks", &lz4DecompressCase, rows);
    cases ~= BenchCase("cityhash128 1 MiB chunks", &cityHashCase, rows);
    cases ~= BenchCase("frame/encode lz4", frameEncode(Compression.lz4), rows);
    cases ~= BenchCase("frame/decode lz4", frameDecode(Compression.lz4), rows);
    cases ~= BenchCase("decode-lz4/6 columns", decodeCompressed(Compression.lz4), rows);
    if (zstdAvailable)
    {
        cases ~= BenchCase("frame/encode zstd", frameEncode(Compression.zstd), rows);
        cases ~= BenchCase("frame/decode zstd", frameDecode(Compression.zstd), rows);
        cases ~= BenchCase("decode-zstd/6 columns", decodeCompressed(Compression.zstd), rows);
    }
    return cases;
}
