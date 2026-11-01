/++
Benchmarks of the row-level APIs: SELECT and INSERT through a `Connection`
whose transport replays scripted server packets (no server), and per-cell
getters on decoded columns (the access path of ddbc).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module benchmarks.api;

import core.time : Duration;
import std.datetime.systime : SysTime;

import clickhoused;
import clickhoused.block : writeBlock;
import clickhoused.compress.frame : CompressedOutput, Compression;
import clickhoused.io.buffer : BufferedWriter;
import clickhoused.io.transport : Transport;
import clickhoused.protocol.codes : Revision, ServerPacket;

import benchmarks.offline : makeBlocks, mix, RecordingTransport, shortText, Spec;
import benchmarks.runner : BenchCase, Prepared;

/++
A transport that replays server packets in segments. A segment is handed out
only when the client reads after consuming the previous one, the way a server
answers only after the client has sent its part. Written bytes are copied into
a reused buffer.
+/
final class ScriptTransport : Transport
{
    private immutable(ubyte)[][] segments;
    private size_t segment;
    private size_t position;
    private ubyte[] output;
    private size_t written;

    /// Creates a transport replaying `segments`.
    this(immutable(ubyte)[][] segments) @safe
    {
        this.segments = segments;
    }

    /// Replays again from the start of segment `index`.
    void rewind(size_t index) @safe
    {
        segment = index;
        position = 0;
        written = 0;
    }

    /// Copies bytes of the current segment, moving to the next one when it is used up.
    size_t read(scope ubyte[] buffer) @safe
    {
        while (segment < segments.length && position == segments[segment].length)
        {
            segment++;
            position = 0;
        }
        if (segment == segments.length)
            return 0;
        const left = segments[segment].length - position;
        const n = buffer.length < left ? buffer.length : left;
        buffer[0 .. n] = segments[segment][position .. position + n];
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

    /// Always false: the script answers only when the client waits.
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

/// A server Hello for a 26.11 server (above the client's revision, which then decides the fields).
immutable(ubyte)[] serverHello()
{
    auto recording = new RecordingTransport;
    auto w = new BufferedWriter(recording);
    w.writeUVarInt(ServerPacket.hello);
    w.writeString("ClickHouse");
    w.writeUVarInt(26);
    w.writeUVarInt(11);
    w.writeUVarInt(54_492);
    w.writeString("UTC");
    w.writeString("bench");
    w.writeUVarInt(1);
    w.flush();
    return recording.data.idup;
}

/// Data packets carrying `blocks` (the first one usually the header), then EndOfStream if `end`.
immutable(ubyte)[] dataPackets(Block[] blocks, Compression compression, bool end)
{
    auto recording = new RecordingTransport;
    auto plain = new BufferedWriter(recording);
    auto blockWriter = compression == Compression.none ? plain
        : new BufferedWriter(new CompressedOutput(plain, compression), 1 << 20);
    foreach (b; blocks)
    {
        plain.writeUVarInt(ServerPacket.data);
        plain.writeString(""); // table name, never compressed
        writeBlock(blockWriter, b, Revision.client);
        if (blockWriter !is plain)
            blockWriter.flush(); // each block ends a frame
    }
    if (end)
        plain.writeUVarInt(ServerPacket.endOfStream);
    plain.flush();
    return recording.data.idup;
}

/// An empty block with the columns of `blocks[0]`: the header the server sends first.
Block headerOf(Block block)
{
    auto header = new Block;
    foreach (c; block.columns)
        header.columns ~= createColumn(c.name, c.typeName, "UTC");
    return header;
}

/// A connection over `transport`.
Connection scriptedConnection(ScriptTransport transport, Compression compression = Compression.none)
{
    ConnectionOptions options;
    options.compression = compression;
    options.transportFactory = (string, ushort, Duration) => cast(Transport) transport;
    return new Connection(options);
}

/// The rows of the query and insert cases.
struct Row
{
    ulong id; ///
    string name; ///
    double value; ///
    SysTime ts; ///
}

/// The columns of `Row`.
Spec[] rowSpecs()
{
    return [
        Spec("id", "UInt64", (c, r) { c.appendUlong(r); }),
        Spec("name", "String", (c, r) { c.appendString(shortText(r)); }),
        Spec("value", "Float64", (c, r) { c.appendDouble((mix(r) % 1_000_000) / 7.0); }),
        Spec("ts", "DateTime64(3, 'UTC')", (c, r) {
            c.appendLong(1_600_000_000_000 + cast(long)(mix(r) % 1_000_000));
        }),
    ];
}

private __gshared double sink; // keeps results alive

/// SELECT and INSERT cases over a scripted connection, and per-cell getter cases.
BenchCase[] apiCases()
{
    BenchCase[] cases;
    enum sql = "SELECT id, name, value, ts FROM t";

    // A connection replaying the result of `sql`, read by `consume`
    Prepared delegate(size_t) queryCase(void delegate(Connection) consume, Compression compression)
    {
        Prepared prepare(size_t rows)
        {
            auto blocks = makeBlocks(rowSpecs(), rows);
            auto transport = new ScriptTransport([
                serverHello(), dataPackets(headerOf(blocks[0]) ~ blocks, compression, true)
            ]);
            auto conn = scriptedConnection(transport, compression);
            void run()
            {
                transport.rewind(1);
                consume(conn);
            }

            return Prepared(rows, dataPackets(blocks, Compression.none, false).length, &run);
        }

        return &prepare;
    }

    void drain(Connection conn)
    {
        foreach (block; conn.query(sql))
        {
        }
    }

    void columns(Connection conn)
    {
        double total = 0;
        foreach (block; conn.query(sql))
        {
            foreach (v; block.column!UInt64Column("id").data)
                total += v;
            foreach (s; block.column!StringColumn("name").data)
                total += s.length;
            foreach (v; block.column!Float64Column("value").data)
                total += v;
            foreach (v; block.column!DateTime64Column("ts").data)
                total += v;
        }
        sink = total;
    }

    void structs(Connection conn)
    {
        double total = 0;
        foreach (row; conn.query!Row(sql))
            total += row.id + row.name.length + row.value + row.ts.stdTime;
        sink = total;
    }

    void getters(Connection conn)
    {
        double total = 0;
        foreach (block; conn.query(sql))
            foreach (r; 0 .. block.rows)
                total += block.columns[0].getLong(r) + block.columns[1].getString(r)
                    .length
                    + block.columns[2].getDouble(r) + block.columns[3].getSysTime(r).stdTime;
        sink = total;
    }

    enum rows = 1_000_000;
    cases ~= BenchCase("query/drain", queryCase(&drain, Compression.none), rows);
    cases ~= BenchCase("query/drain lz4", queryCase(&drain, Compression.lz4), rows);
    cases ~= BenchCase("query/columns", queryCase(&columns, Compression.none), rows);
    cases ~= BenchCase("query/query!T structs", queryCase(&structs, Compression.none), rows);
    cases ~= BenchCase("query/per-cell getters", queryCase(&getters, Compression.none), rows);

    // INSERT: the server sends the header, then EndOfStream after the data
    Prepared delegate(size_t) insertCase(void delegate(Connection, Block[]) send)
    {
        Prepared prepare(size_t rows)
        {
            auto blocks = makeBlocks(rowSpecs(), rows);
            auto transport = new ScriptTransport([
                serverHello(), dataPackets([headerOf(blocks[0])], Compression.none, false),
                dataPackets(null, Compression.none, true)
            ]);
            auto conn = scriptedConnection(transport);
            void run()
            {
                transport.rewind(1);
                send(conn, blocks);
            }

            return Prepared(rows, dataPackets(blocks, Compression.none, false).length, &run);
        }

        return &prepare;
    }

    Row[] rowsOf(Block[] blocks)
    {
        Row[] all;
        foreach (b; blocks)
            foreach (r; 0 .. b.rows)
                all ~= Row(b.columns[0].getUlong(r), b.columns[1].getString(r), b.columns[2].getDouble(r),
                        b.columns[3].getSysTime(r));
        return all;
    }

    Row[] cachedRows;
    void addRows(Connection conn, Block[] blocks)
    {
        if (cachedRows is null)
            cachedRows = rowsOf(blocks);
        auto ins = conn.beginInsert("INSERT INTO t VALUES");
        foreach (ref row; cachedRows)
            ins.addRow(row.id, row.name, row.value, row.ts);
        ins.finish();
    }

    Row[] cachedStructs;
    void insertStructs(Connection conn, Block[] blocks)
    {
        if (cachedStructs is null)
            cachedStructs = rowsOf(blocks);
        conn.insert("t", cachedStructs);
    }

    void insertBlocks(Connection conn, Block[] blocks)
    {
        auto ins = conn.beginInsert("INSERT INTO t VALUES");
        foreach (b; blocks)
            ins.send(b);
        ins.finish();
    }

    cases ~= BenchCase("insert/addRow", insertCase(&addRows), rows);
    cases ~= BenchCase("insert/structs", insertCase(&insertStructs), rows);
    cases ~= BenchCase("insert/blocks", insertCase(&insertBlocks), rows);

    // Per-cell getters on decoded columns
    BenchCase cellCase(string label, string type, Spec spec, double delegate(Column, size_t) get,
            size_t defaultRows = rows)
    {
        Prepared prepare(size_t n)
        {
            spec.type = type;
            auto blocks = makeBlocks([spec], n);
            void run()
            {
                double total = 0;
                foreach (b; blocks)
                    foreach (r; 0 .. b.rows)
                        total += get(b.columns[0], r);
                sink = total;
            }

            return Prepared(n, 0, &run);
        }

        return BenchCase("cells/" ~ label, &prepare, defaultRows);
    }

    auto specs = rowSpecs();
    cases ~= cellCase("getLong UInt64", "UInt64", specs[0], (c, r) => c.getLong(r));
    cases ~= cellCase("getVariant UInt64", "UInt64", specs[0], (c, r) => cast(double) c.getVariant(r).get!ulong);
    cases ~= cellCase("readValue!long UInt64", "UInt64", specs[0], (c, r) => readValue!long(c, r));
    cases ~= cellCase("getString String", "String", specs[1], (c, r) => c.getString(r).length);
    cases ~= cellCase("getString Float64", "Float64", specs[2], (c, r) => c.getString(r).length, 100_000);
    cases ~= cellCase("getSysTime DateTime64(3)", "DateTime64(3, 'UTC')", specs[3], (c, r) => c.getSysTime(r).stdTime);
    cases ~= cellCase("getString DateTime64(3)", "DateTime64(3, 'UTC')", specs[3], (c, r) => c.getString(r)
            .length,
            100_000);
    cases ~= cellCase("getSysTime DateTime64(3, Europe/Lisbon)", "DateTime64(3, 'Europe/Lisbon')", specs[3],
            (c, r) => c.getSysTime(r).stdTime);
    cases ~= cellCase("getString Decimal(18, 4)", "Decimal(18, 4)", Spec("c", "", (c, r) {
            c.appendLong(cast(long)(mix(r) % 1_000_000_000));
        }), (c, r) => c.getString(r).length, 100_000);
    return cases;
}
