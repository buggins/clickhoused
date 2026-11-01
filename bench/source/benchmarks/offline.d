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
final class RecordingTransport : Transport
{
    /// Everything written.
    ubyte[] data;

    /// Reads nothing.
    size_t read(scope ubyte[]) @safe
    {
        return 0;
    }

    /// Keeps `bytes`.
    void write(scope const(ubyte)[] bytes) @safe
    {
        data ~= bytes;
    }

    /// Always false.
    bool dataAvailable() @safe
    {
        return false;
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

/// Fills a column with the value of row `row` (deterministic).
alias Fill = void function(Column column, size_t row);

/// A column of generated blocks: name, type and how its values are made.
struct Spec
{
    string name; ///
    string type; ///
    Fill fill; ///
}

/// Blocks of `rows` rows in total, `blockSize` rows each, with the columns `specs`.
Block[] makeBlocks(const Spec[] specs, size_t rows, size_t blockSize = blockRows)
{
    Block[] blocks;
    for (size_t start = 0; start < rows; start += blockSize)
    {
        const count = rows - start < blockSize ? rows - start : blockSize;
        auto block = new Block;
        foreach (spec; specs)
        {
            auto column = createColumn(spec.name, spec.type, "UTC");
            foreach (row; start .. start + count)
                spec.fill(column, row);
            block.columns ~= column;
        }
        block.rows = count;
        blocks ~= block;
    }
    return blocks;
}

/// ditto, one column `c` of `typeName`.
Block[] makeBlocks(string typeName, size_t rows, Fill fill)
{
    return makeBlocks([Spec("c", typeName, fill)], rows);
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
    return decodeCase([Spec("c", typeName, fill)], label.length ? label : typeName, defaultRows);
}

/// ditto, for blocks of several columns and `blockSize` rows.
BenchCase decodeCase(const Spec[] specs, string label, size_t defaultRows, size_t blockSize = blockRows)
{
    Prepared prepare(size_t rows)
    {
        const bytes = encode(makeBlocks(specs, rows, blockSize));
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

    return BenchCase("decode/" ~ label, &prepare, defaultRows);
}

/// An encoding case: writes all blocks of the input.
BenchCase encodeCase(string typeName, Fill fill, size_t defaultRows = 1_000_000, string label = null)
{
    return encodeCase([Spec("c", typeName, fill)], label.length ? label : typeName, defaultRows);
}

/// ditto, for blocks of several columns and `blockSize` rows.
BenchCase encodeCase(const Spec[] specs, string label, size_t defaultRows, size_t blockSize = blockRows)
{
    Prepared prepare(size_t rows)
    {
        auto blocks = makeBlocks(specs, rows, blockSize);
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

    return BenchCase("encode/" ~ label, &prepare, defaultRows);
}

/// A pseudo-random number for `row` (a fixed permutation, so runs are repeatable).
ulong mix(size_t row) @safe pure nothrow @nogc
{
    ulong x = row * 0x9E37_79B9_7F4A_7C15UL;
    x ^= x >> 29;
    x *= 0xBF58_476D_1CE4_E5B9UL;
    return x ^ (x >> 32);
}

/// A 10-byte text for `row`.
string shortText(size_t row)
{
    import std.format : format;

    return format("s%09d", mix(row) % 1_000_000_000); // 10 bytes
}

/// A 1 KB text for `row`.
string longText(size_t row)
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

/// The columns of the wide-block cases: a mix of common types.
Spec[] mixedSpecs(size_t columns)
{
    static immutable Spec[] kinds = [
        Spec("", "UInt64", (c, r) { c.appendUlong(mix(r)); }),
        Spec("", "String", (c, r) { c.appendString(shortText(r)); }),
        Spec("", "Float64", (c, r) { c.appendDouble((mix(r) % 1_000_000) / 7.0); }),
        Spec("", "Nullable(Int32)", (c, r) {
            if (mix(r) % 10 == 0)
                c.appendNull();
            else
                c.appendLong(cast(int) mix(r));
        }),
        Spec("", "DateTime", (c, r) { c.appendLong(mix(r) % 4_000_000_000); }),
        Spec("", "LowCardinality(String)", (c, r) { c.appendString(shortText(mix(r) % 100)); }),
    ];
    Spec[] specs;
    foreach (i; 0 .. columns)
    {
        import std.conv : to;

        const kind = kinds[i % kinds.length];
        specs ~= Spec("c" ~ i.to!string, kind.type, kind.fill);
    }
    return specs;
}

/// The composite and new types, decoded and encoded; a wide block and many small blocks.
BenchCase[] compositeCases()
{
    import std.format : format;
    import std.typecons : tuple, Tuple;
    import clickhoused.insert : appendValue;

    struct TypeCase
    {
        string type;
        Fill fill;
        size_t rows;
        string label;
    }

    TypeCase[] types = [
        TypeCase("LowCardinality(String)", (c, r) { c.appendString(shortText(mix(r) % 100)); }, 1_000_000,
                "LowCardinality(String) 100 keys"),
        TypeCase("Nullable(String)", (c, r) {
            if (mix(r) % 10 == 0)
                c.appendNull();
            else
                c.appendString(shortText(r));
        }, 1_000_000),
        TypeCase("Array(UInt32)", (c, r) {
            uint[] values;
            foreach (i; 0 .. mix(r) % 17)
                values ~= cast(uint) mix(r + i);
            appendValue(c, values);
        }, 1_000_000, "Array(UInt32) avg 8"),
        TypeCase("Array(String)", (c, r) {
            string[] values;
            foreach (i; 0 .. mix(r) % 9)
                values ~= shortText(r + i);
            appendValue(c, values);
        }, 1_000_000, "Array(String) avg 4"),
        TypeCase("Map(String, UInt64)", (c, r) {
            Tuple!(string, ulong)[] entries;
            foreach (i; 0 .. mix(r) % 9)
                entries ~= tuple(shortText(i), mix(r + i));
            appendValue(c, entries);
        }, 1_000_000, "Map(String, UInt64) avg 4"),
        TypeCase("Tuple(UInt64, String)", (c, r) { appendValue(c, tuple(mix(r), shortText(r))); }, 1_000_000),
        TypeCase("Decimal(18, 4)", (c, r) {
            c.appendString(format("%d.%04d", mix(r) % 100_000_000, mix(r) % 10_000));
        }, 1_000_000),
        TypeCase("Int128", (c, r) { c.appendLong(cast(long) mix(r)); }, 1_000_000),
        TypeCase("IPv6", (c, r) {
            c.appendString(format("2001:db8::%x:%x", mix(r) % 65_536, r % 65_536));
        },
                1_000_000),
        TypeCase("Variant(String, UInt64)", (c, r) {
            if (r % 2)
                c.appendString(shortText(r));
            else
                c.appendUlong(mix(r));
        }, 1_000_000),
        TypeCase("Dynamic", (c, r) {
            final switch (r % 3)
            {
            case 0:
                c.appendLong(cast(long) mix(r));
                break;
            case 1:
                c.appendString(shortText(r));
                break;
            case 2:
                c.appendDouble((mix(r) % 1000) / 7.0);
                break;
            }
        }, 1_000_000, "Dynamic 3 types"),
        TypeCase("JSON", (c, r) {
            enum json = `{"id":%d,"name":"%s","tags":["a","b"],"score":%d.5}`;
            c.appendString(format(json, r, shortText(r), mix(r) % 100));
        }, 100_000, "JSON ~60 B"),
    ];
    BenchCase[] cases;
    foreach (t; types)
        cases ~= decodeCase(t.type, t.fill, t.rows, t.label);
    foreach (t; types)
        cases ~= encodeCase(t.type, t.fill, t.rows, t.label);
    cases ~= decodeCase(mixedSpecs(24), "wide 24 columns", 200_000);
    cases ~= encodeCase(mixedSpecs(24), "wide 24 columns", 200_000);
    cases ~= decodeCase(mixedSpecs(6), "6 columns, 1000-row blocks", 200_000, 1000);
    cases ~= encodeCase(mixedSpecs(6), "6 columns, 1000-row blocks", 200_000, 1000);
    return cases;
}
