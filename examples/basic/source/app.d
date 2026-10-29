/++
Basic clickhoused usage: connect, create a table, insert structs, query them
back, aggregate, and read a result block by block.

Run with `dub run :example-basic`. The server address comes from the
`CLICKHOUSE_DSN` environment variable (default `clickhouse://localhost`).
+/
module app;

import std.datetime : DateTime, SysTime, UTC, msecs;
import std.process : environment;
import std.stdio : writefln, writeln;

import clickhoused;

/// One row of the `example_trades` table.
struct Trade
{
    /// Trade time; stored in the column `ts`.
    @column("ts") SysTime time;
    /// Instrument.
    string symbol;
    /// Price per unit.
    double price;
    /// Number of units.
    uint quantity;
}

void main()
{
    auto conn = new Connection(environment.get("CLICKHOUSE_DSN", "clickhouse://localhost"));
    scope (exit)
        conn.close();
    writefln("Connected to %s %s.%s on %s", conn.serverInfo.name, conn.serverInfo.versionMajor,
            conn.serverInfo.versionMinor, conn.host);

    // A temporary table lives as long as the connection
    conn.exec(`CREATE TEMPORARY TABLE example_trades (ts DateTime64(3, 'UTC'), symbol String,
               price Float64, quantity UInt32) ENGINE = Memory`);

    // Insert structs; columns are matched to fields by name (`ts` via @column)
    Trade[] trades;
    const start = SysTime(DateTime(2025, 10, 29, 9, 30, 0), UTC());
    foreach (i; 0 .. 10)
        trades ~= Trade(start + (i * 250).msecs, i % 2 ? "AAPL" : "MSFT", 100.0 + i, 10 * (i + 1));
    conn.insert("example_trades", trades);

    // Read structs back, with a server-side query parameter
    foreach (t; conn.query!Trade("SELECT * FROM example_trades WHERE symbol = {sym:String} ORDER BY ts",
            null, ["sym": "AAPL"]))
        writefln("%s  %-5s %8.2f x %s", t.time.toISOExtString(), t.symbol, t.price, t.quantity);

    // Single values
    const count = conn.queryValue!ulong("SELECT count() FROM example_trades");
    const volume = conn.queryValue!double("SELECT sum(price * quantity) FROM example_trades");
    writefln("%s trades, volume %.2f", count, volume);

    // Columnar access: whole columns as D arrays, block by block
    foreach (block; conn.query("SELECT symbol, avg(price) AS avg_price FROM example_trades GROUP BY symbol"))
    {
        auto symbols = block.column!StringColumn("symbol").data;
        auto averages = block.column!Float64Column("avg_price").data;
        foreach (i; 0 .. block.rows)
            writefln("%-5s average %.2f", symbols[i], averages[i]);
    }

    // Network compression is one option away
    auto options = ConnectionOptions.fromDsn(environment.get("CLICKHOUSE_DSN", "clickhouse://localhost"));
    options.compression = Compression.lz4;
    auto compressed = new Connection(options);
    scope (exit)
        compressed.close();
    writeln("LZ4 connection: ", compressed.queryValue!string("SELECT 'compressed hello'"));
}
