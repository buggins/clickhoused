# clickhoused

[![CI](https://github.com/buggins/clickhoused/actions/workflows/ci.yml/badge.svg)](https://github.com/buggins/clickhoused/actions/workflows/ci.yml)
[![License: BSL-1.0](https://img.shields.io/badge/license-BSL--1.0-blue.svg)](LICENSE)

A native [ClickHouse](https://clickhouse.com) client library for the [D programming language](https://dlang.org).

- **Pure D.** It implements the ClickHouse native TCP protocol (port 9000) directly. LZ4 compression is built in; nothing else is needed.
- **Threads and fibers.** It works in ordinary threads (Phobos sockets) and in [vibe.d](https://vibed.org) tasks (vibe-core sockets), and chooses automatically. vibe-core is used only if your project depends on it.
- **Structs or columns.** Map query results to D structs, or process whole columns as D arrays.
- **Streaming** in both directions, a **connection pool**, **failover** between servers, and **cancellation**.

Supports ClickHouse 23.8 and newer, and D compilers with frontend 2.105 or newer (DMD 2.105+, LDC 1.35+, GDC 14+).

> **Status: 0.1.0, early release.** The API may still change before 1.0. TLS and composite types (Array, Tuple, Map) are not supported yet; see [Limitations](#limitations).

## Installation

Add clickhoused to your `dub.json`:

```json
"dependencies": {
    "clickhoused": "~>0.1.0"
}
```

## Quick start

```d
import clickhoused;
import std.datetime;
import std.stdio;

struct Trade
{
    @column("ts") SysTime time;   // maps to column `ts`
    string symbol;
    double price;
    uint quantity;
}

void main()
{
    auto conn = new Connection("clickhouse://default:@localhost:9000/default");
    scope (exit) conn.close();

    conn.exec(`CREATE TABLE IF NOT EXISTS trades (ts DateTime64(3), symbol LowCardinality(String),
               price Float64, quantity UInt32) ENGINE = MergeTree ORDER BY ts`);

    Trade[] trades = [Trade(Clock.currTime, "AAPL", 230.5, 100)];
    conn.insert("trades", trades);                      // any range of structs

    // Rows as structs; {sym:String} is a server-side query parameter
    foreach (t; conn.query!Trade("SELECT * FROM trades WHERE symbol = {sym:String}", null, ["sym": "AAPL"]))
        writeln(t.time, " ", t.price);

    // A single value
    const count = conn.queryValue!ulong("SELECT count() FROM trades");

    // Whole columns as D arrays, block by block
    foreach (block; conn.query("SELECT price FROM trades"))
        writeln(block.column!Float64Column("price").data);
}
```

Runnable examples: [`examples/basic`](examples/basic/source/app.d) (`dub run :example-basic`) and [`examples/vibe`](examples/vibe/source/app.d) (`dub run :example-vibe`).

## Usage

### Connecting

```d
auto conn = new Connection("clickhouse://user:password@host1:9000,host2:9000/db?compress=lz4&max_threads=4");
```

- **Several hosts** are tried in order, and the first that answers is used. Add `host_selection=random` to spread connections over them.
- **Options:** `compress` (`none`, `lz4`, `zstd`), `connect_timeout`, `send_timeout`, `receive_timeout` (seconds), `io` (`auto`, `phobos`, `vibe`), `client_name`, `quota_key`.
- **Settings:** any other parameter is sent to the server as a setting.

All options are also available as fields of `ConnectionOptions`, for building them in code.

### Queries

- `conn.query(sql)` returns the result as a lazy range of blocks.
  - Each block's columns are typed arrays (`UInt64Column.data` is a `ulong[]`).
  - Every column also has per-cell getters with conversions: `getLong`, `getString`, `getSysTime`, `isNull`, `getVariant`, and others.
- `conn.query!T(sql)`, `conn.queryRow!T(sql)` and `conn.queryValue!T(sql)` map the result to structs or values.
- `conn.exec(sql)` runs a statement and returns its statistics.
- **Parameters:** placeholders like `{name:Type}` are filled from the `parameters` argument on the server, so values are never mixed into the SQL text.
- **Literals:** where parameters cannot be used, `formatLiteral(value)` produces a safe SQL literal.
- **Ending early:** a result keeps the connection busy until it is read to the end or closed. `result.close()` cancels the query, and `conn.cancel()` works from another thread or task.

### Inserting

```d
auto ins = conn.beginInsert("INSERT INTO trades (ts, symbol, price, quantity) VALUES");
scope (failure) ins.abort();
foreach (row; source)
    ins.addRow(row.time, row.symbol, row.price, row.quantity);   // sent in blocks automatically
ins.finish();
```

`ins.addStruct(s)` adds a struct instead. `conn.insert(table, block)` inserts a ready-made block, and `conn.insert(table, structs)` a range of structs. Values are converted to the column types with range checks.

### Connection pool

```d
auto pool = new ConnectionPool("clickhouse://localhost/default?pool_max=8");
{
    auto conn = pool.lockConnection();   // returned to the pool at the end of the scope
    conn.exec("...");
}
```

- **Threads:** all threads share the connections.
- **vibe.d:** each thread has its own set, because a vibe.d connection cannot move between event loops.
- **Options:** `pool_max`, `pool_wait_timeout`, `pool_max_idle_time`, `pool_max_lifetime`, `pool_ping_after_idle`.

### vibe.d

Nothing special is needed. Inside a vibe.d task, connections automatically use vibe-core sockets, so waiting for ClickHouse suspends only that task.

### Compression

`compress=lz4` (or `ConnectionOptions.compression = Compression.lz4`) is pure D and always available. It usually pays off for remote servers.

`compress=zstd` uses the system zstd library and needs the `zstd` configuration:

```json
"subConfigurations": { "clickhoused": "zstd" }
```

## Supported types

| ClickHouse | D column class | D value |
|---|---|---|
| `UInt8`…`UInt64`, `Int8`…`Int64` | `UInt8Column`…`Int64Column` | `ubyte`…`long` |
| `Float32`, `Float64` | `Float32Column`, `Float64Column` | `float`, `double` |
| `Bool` | `BoolColumn` | `bool` |
| `String`, `FixedString(N)` | `StringColumn`, `FixedStringColumn` | `string`, `ubyte[]` |
| `Date`, `Date32` | `DateColumn`, `Date32Column` | `Date` |
| `DateTime[(tz)]`, `DateTime64(p[, tz])` | `DateTimeColumn`, `DateTime64Column` | `SysTime` |
| `UUID` | `UUIDColumn` | `UUID` |
| `Enum8`, `Enum16` | `Enum8Column`, `Enum16Column` | label `string`, or a D `enum` |
| `Nullable(T)` | `NullableColumn` | `Nullable!T` |
| `LowCardinality(T)` | received as `T` | |

## Limitations

- No TLS yet. Use a private network or an SSH tunnel.
- Not supported yet: `Array`, `Tuple`, `Map`, `Decimal`, 128/256-bit integers, `IPv4`/`IPv6`, geo types, `Variant`/`Dynamic`/`JSON`. A query returning such a column fails with a clear error.
- On Windows, timezone names fall back to UTC (no system timezone database). The point in time stays correct.

## Building and testing

```sh
dub build                                     # library
dub test                                      # unit tests, no server needed
CLICKHOUSE_HOST=localhost:9000 dub run :integration-tests-phobos   # integration tests, threads
CLICKHOUSE_HOST=localhost:9000 dub run :integration-tests-vibe     # integration tests, vibe.d fibers
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md), and third-party code in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[Boost Software License 1.0](LICENSE).

This is an unofficial project. It is not affiliated with or endorsed by ClickHouse, Inc. ClickHouse is a trademark of ClickHouse, Inc.
