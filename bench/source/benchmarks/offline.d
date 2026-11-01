/++
Offline benchmarks: decoding and encoding native-format blocks in memory, with
no server, so they measure only the client's CPU cost. Inputs are split into
blocks of 65,536 rows, about the size the server sends.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module benchmarks.offline;

import core.time : Duration;
import std.datetime.date : Date;
import std.uuid : UUID;

import clickhoused;
import clickhoused.block : readBlock, writeBlock;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.io.transport : Transport;
import clickhoused.protocol.codes : Revision;

import benchmarks.runner : BenchCase, Prepared;

/// Rows per block, as the server's default `max_block_size` roughly gives.
enum blockRows = 65_536;

/++
A transport reading from fixed bytes (rewound with `reset`). Written bytes
are copied into a reused buffer, as a socket send copies them, so encoding
pays for the copy.
+/
final class MemoryTransport : Transport
{
    private immutable(ubyte)[] input;
    private size_t position;
    private ubyte[] output;
    /// Bytes written since the last `reset`.
    size_t written;

    /// Creates a transport that reads `input`.
    this(immutable(ubyte)[] input = null) @safe
    {
        this.input = input;
    }

    /// Reads `input` again from the start, and forgets written bytes.
    void reset() @safe
    {
        position = 0;
        written = 0;
    }

    /// Copies the next input bytes into `buffer`.
    size_t read(scope ubyte[] buffer) @safe
    {
        const n = buffer.length < input.length - position ? buffer.length : input.length - position;
        buffer[0 .. n] = input[position .. position + n];
        position += n;
        return n;
    }

    /// Copies `data` into the output buffer.
    void write(scope const(ubyte)[] data) @safe
    {
        if (output.length < written + data.length)
            output.length = (written + data.length) * 2;
        output[written .. written + data.length] = data[];
        written += data.length;
    }

    /// Whether input is left.
    bool dataAvailable() @safe
    {
        return position < input.length;
    }

    /// Does nothing.
    void close() @safe nothrow
    {
    }

    /// Always true.
    bool connected() const @safe nothrow
    {
        return true;
    }

    /// Does nothing.
    void setTimeouts(Duration, Duration) @safe
    {
    }
}

/// A transport that keeps what is written.
private final class RecordingTransport : Transport
{
    ubyte[] data;

    size_t read(scope ubyte[]) @safe
    {
        return 0;
    }

    void write(scope const(ubyte)[] bytes) @safe
    {
        data ~= bytes;
    }

    bool dataAvailable() @safe
    {
        return false;
    }

    void close() @safe nothrow
    {
    }

    bool connected() const @safe nothrow
    {
        return true;
    }

    void setTimeouts(Duration, Duration) @safe
    {
    }
}

/// Fills a column with the value of row `row` (deterministic).
alias Fill = void function(Column column, size_t row);

/// Blocks of `rows` rows in total, one column of `typeName`, filled by `fill`.
Block[] makeBlocks(string typeName, size_t rows, Fill fill)
{
    Block[] blocks;
    for (size_t start = 0; start < rows; start += blockRows)
    {
        const count = rows - start < blockRows ? rows - start : blockRows;
        auto column = createColumn("c", typeName, "UTC");
        foreach (row; start .. start + count)
            fill(column, row);
        auto block = new Block;
        block.columns = [column];
        block.rows = count;
        blocks ~= block;
    }
    return blocks;
}

/// `blocks` in the native format, as the server sends them at our revision.
immutable(ubyte)[] encode(Block[] blocks)
{
    auto recording = new RecordingTransport;
    auto writer = new BufferedWriter(recording);
    foreach (b; blocks)
        writeBlock(writer, b, Revision.client);
    writer.flush();
    return recording.data.idup;
}

/// A decoding case: reads all blocks of the input.
BenchCase decodeCase(string typeName, Fill fill, size_t defaultRows = 1_000_000, string label = null)
{
    Prepared prepare(size_t rows)
    {
        const bytes = encode(makeBlocks(typeName, rows, fill));
        auto transport = new MemoryTransport(bytes);
        void run()
        {
            transport.reset();
            auto reader = new BufferedReader(transport);
            size_t read;
            while (read < rows)
                read += readBlock(reader, Revision.client, "UTC").rows;
        }

        return Prepared(rows, bytes.length, &run);
    }

    return BenchCase("decode/" ~ (label.length ? label : typeName), &prepare, defaultRows);
}

/// An encoding case: writes all blocks of the input.
BenchCase encodeCase(string typeName, Fill fill, size_t defaultRows = 1_000_000, string label = null)
{
    Prepared prepare(size_t rows)
    {
        auto blocks = makeBlocks(typeName, rows, fill);
        auto transport = new MemoryTransport;
        size_t bytes;
        void run()
        {
            transport.reset();
            auto writer = new BufferedWriter(transport);
            foreach (b; blocks)
                writeBlock(writer, b, Revision.client);
            writer.flush();
            bytes = transport.written;
        }

        run();
        return Prepared(rows, bytes, &run);
    }

    return BenchCase("encode/" ~ (label.length ? label : typeName), &prepare, defaultRows);
}

/// A pseudo-random number for `row` (a fixed permutation, so runs are repeatable).
ulong mix(size_t row) @safe pure nothrow @nogc
{
    ulong x = row * 0x9E37_79B9_7F4A_7C15UL;
    x ^= x >> 29;
    x *= 0xBF58_476D_1CE4_E5B9UL;
    return x ^ (x >> 32);
}

private string shortText(size_t row)
{
    import std.format : format;

    return format("s%09d", mix(row) % 1_000_000_000); // 10 bytes
}

private string longText(size_t row)
{
    import std.array : replicate;

    static immutable base = "0123456789abcdef".replicate(64); // 1 KB
    auto s = base.dup;
    s[0 .. 10] = shortText(row);
    return s.idup;
}

/// The basic-type cases: each type decoded and encoded.
BenchCase[] basicCases()
{
    struct TypeCase
    {
        string type;
        Fill fill;
        size_t rows;
        string label;
    }

    static immutable enumType = "Enum8('a' = 1, 'b' = 2, 'c' = 3)";
    TypeCase[] types = [
        TypeCase("UInt64", (c, r) { c.appendUlong(mix(r)); }, 1_000_000),
        TypeCase("Int32", (c, r) { c.appendLong(cast(int) mix(r)); }, 1_000_000),
        TypeCase("Float64", (c, r) { c.appendDouble((mix(r) % 1_000_000) / 7.0); }, 1_000_000),
        TypeCase("Bool", (c, r) { c.appendBool((mix(r) & 1) != 0); }, 1_000_000),
        TypeCase("String", (c, r) { c.appendString(shortText(r)); }, 1_000_000, "String(10 B)"),
        TypeCase("String", (c, r) { c.appendString(longText(r)); }, 100_000, "String(1 KB)"),
        TypeCase("FixedString(16)", (c, r) { c.appendString(shortText(r) ~ "abcdef"); }, 1_000_000),
        TypeCase("Nullable(Int64)", (c, r) {
            if (mix(r) % 10 == 0)
                c.appendNull();
            else
                c.appendLong(cast(long) mix(r));
        }, 1_000_000),
        TypeCase("Date", (c, r) { c.appendDate(Date(2000, 1, 1) + (cast(long)(mix(r) % 10_000)).days); }, 1_000_000),
        TypeCase("DateTime", (c, r) { c.appendLong(mix(r) % 4_000_000_000); }, 1_000_000),
        TypeCase("DateTime64(3)", (c, r) { c.appendLong(cast(long)(mix(r) % 4_000_000_000_000)); }, 1_000_000),
        TypeCase("UUID", (c, r) {
            ubyte[16] b;
            b[0 .. 8] = (cast(ubyte*)[mix(r)].ptr)[0 .. 8];
            c.appendUUID(UUID(b));
        }, 1_000_000),
        TypeCase(enumType, (c, r) { c.appendString(["a", "b", "c"][mix(r) % 3]); }, 1_000_000, "Enum8"),
    ];
    BenchCase[] cases;
    foreach (t; types)
        cases ~= decodeCase(t.type, t.fill, t.rows, t.label);
    foreach (t; types)
        cases ~= encodeCase(t.type, t.fill, t.rows, t.label);
    return cases;
}

private Duration days(long n) @safe pure nothrow
{
    import core.time : dur;

    return dur!"days"(n);
}
