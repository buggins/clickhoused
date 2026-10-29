/// Network compression tests: data is really compressed on the wire, in both directions.
module integrationtests.compression;

import core.time : Duration;
import std.conv : to;
import std.exception : enforce;

import clickhoused;
import clickhoused.io.backend : backendFor;
import integrationtests.basic : firstBlock;
import integrationtests.server : serverOptions;

/// A transport that counts the bytes passing through it.
final class CountingTransport : Transport
{
    private Transport inner;
    /// Bytes received.
    size_t bytesRead;
    /// Bytes sent.
    size_t bytesWritten;

    /// Wraps `inner`.
    this(Transport inner) @safe
    {
        this.inner = inner;
    }

    override size_t read(ubyte[] buffer) @safe
    {
        const n = inner.read(buffer);
        bytesRead += n;
        return n;
    }

    override void write(const(ubyte)[] data) @safe
    {
        bytesWritten += data.length;
        inner.write(data);
    }

    override bool dataAvailable() @safe
    {
        return inner.dataAvailable();
    }

    override void close() @safe nothrow
    {
        inner.close();
    }

    override bool connected() const @safe nothrow
    {
        return inner.connected;
    }

    override void setTimeouts(Duration receive, Duration send) @safe
    {
        inner.setTimeouts(receive, send);
    }
}

/// Bytes on the wire for a SELECT and an INSERT of repetitive data, with `method`.
private size_t[2] measure(Compression method)
{
    auto options = serverOptions();
    options.compression = method;
    CountingTransport counter;
    options.transportFactory = (string host, ushort port, Duration timeout) @safe {
        counter = new CountingTransport(backendFor(options.ioMode).connect(host, port, timeout));
        return cast(Transport) counter;
    };
    auto conn = new Connection(options);
    scope (exit)
        conn.close();

    // SELECT: about 3 MB of repetitive text
    size_t before = counter.bytesRead;
    size_t rows;
    foreach (block; conn.query("SELECT number, repeat('abc', 100) AS s FROM numbers(10000)"))
    {
        auto s = block.column!StringColumn("s");
        foreach (v; s.data)
            enforce(v.length == 300, "bad value");
        rows += block.rows;
    }
    enforce(rows == 10_000, "rows: " ~ rows.to!string);
    const selectBytes = counter.bytesRead - before;

    // INSERT: about 3 MB of repetitive text, then check it arrived intact
    conn.exec("CREATE TEMPORARY TABLE compressed_ins (id UInt64, s String) ENGINE = Memory");
    before = counter.bytesWritten;
    enum text = "xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz"
        ~ "-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz-xyz";
    auto ins = conn.beginInsert("INSERT INTO compressed_ins VALUES");
    foreach (ulong i; 0 .. 10_000)
        ins.addRow(i, text);
    ins.finish();
    const insertBytes = counter.bytesWritten - before;
    auto check = conn.firstBlock("SELECT count() AS c, sum(length(s)) AS l FROM compressed_ins");
    enforce(check.column!UInt64Column("c").data == [10_000], "inserted rows");
    enforce(check.column!UInt64Column("l").data == [10_000 * text.length], "inserted text");

    // Totals and extremes blocks are compressed too
    auto result = conn.query("SELECT number % 3 AS k, count() AS c FROM numbers(100) GROUP BY k WITH TOTALS",
            ["extremes": "1"]);
    foreach (block; result)
    {
    }
    enforce(result.totals !is null && result.totals.column!UInt64Column("c").data == [100], "totals");
    enforce(result.extremes !is null && result.extremes.rows == 2, "extremes");
    return [selectBytes, insertBytes];
}

/// LZ4 (and ZSTD, if compiled in) shrink the traffic in both directions.
void testCompression()
{
    const plain = measure(Compression.none);
    Compression[] methods = [Compression.lz4];
    static if (zstdAvailable)
        methods ~= Compression.zstd;
    foreach (method; methods)
    {
        const packed = measure(method);
        enforce(packed[0] * 10 < plain[0], method.to!string ~ ": SELECT not compressed: " ~ packed[0].to!string
                ~ " vs " ~ plain[0].to!string ~ " bytes");
        enforce(packed[1] * 10 < plain[1], method.to!string ~ ": INSERT not compressed: " ~ packed[1].to!string
                ~ " vs " ~ plain[1].to!string ~ " bytes");
    }
}
