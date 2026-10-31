# clickhoused

[![CI](https://github.com/buggins/clickhoused/actions/workflows/ci.yml/badge.svg)](https://github.com/buggins/clickhoused/actions/workflows/ci.yml)
[![DUB](https://img.shields.io/dub/v/clickhoused)](https://code.dlang.org/packages/clickhoused)
[![Docs](https://img.shields.io/badge/docs-dpldocs-blue.svg)](https://clickhoused.dpldocs.info/)
[![License: BSL-1.0](https://img.shields.io/badge/license-BSL--1.0-blue.svg)](LICENSE)

A native [ClickHouse](https://clickhouse.com) client library for the [D programming language](https://dlang.org).

- **Pure D.** It implements the ClickHouse native TCP protocol (port 9000) directly. LZ4 compression is built in; nothing else is needed.
- **TLS** (port 9440, e.g. ClickHouse Cloud) through the system's OpenSSL, loaded only when a secure connection is made.
- **Threads and fibers.** It works in ordinary threads (Phobos sockets) and in [vibe.d](https://vibed.org) tasks (vibe-core sockets), and chooses automatically. vibe-core is used only if your project depends on it.
- **Structs or columns.** Map query results to D structs, or process whole columns as D arrays.
- **Streaming** in both directions, a **connection pool**, **failover** between servers, and **cancellation**.

Supports ClickHouse 23.8 and newer, and D compilers with frontend 2.097 or newer (DMD 2.097+, LDC 1.27+, GDC 12+).

> **Status: early release (0.x).** The API may still change before 1.0. See [Limitations](#limitations) and the [tracking issue](https://github.com/buggins/clickhoused/issues/10) for the types still to come.

## Installation

clickhoused is on [code.dlang.org](https://code.dlang.org/packages/clickhoused). Add it to your `dub.json`:

```json
"dependencies": {
    "clickhoused": "~>0.3.0"
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
- **Options:** `compress` (`none`, `lz4`, `zstd`), `connect_timeout`, `send_timeout`, `receive_timeout` (seconds), `io` (`auto`, `phobos`, `vibe`), `client_name`, `quota_key`, and the [TLS](#tls) options (`secure`, ...).
- **Ports** default to 9000, or 9440 with `secure=true`.
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

### TLS

Add `secure=true` (or set `ConnectionOptions.secure`). The port then defaults to 9440:

```d
auto conn = new Connection("clickhouse://user:password@abc123.eu-west-1.aws.clickhouse.cloud/default?secure=true");
writeln(conn.tlsVersion); // e.g. "TLSv1.3"
```

- **Verification:** the server certificate and host name are checked against the system's trusted certificates (on Windows, the Windows certificate store); TLS 1.2 or newer is required. For a private CA, add `tls_ca_file=/path/to/ca.pem`. `skip_verify=true` turns verification off; use it only for development.
- **Client certificates:** `tls_cert_file` and `tls_key_file` (PEM files). ClickHouse can log in a user by certificate alone (`ssl_certificates` in the user's settings).
- **Server name:** `tls_server_name=db.example.com` sets the name that is sent and verified, when you connect through an IP address or a tunnel.
- In code, the same settings are in `ConnectionOptions.tls` (`TlsOptions`).

TLS uses the system's OpenSSL library (1.1.1 or 3.x). It is loaded when the first secure connection is made, so builds that never use TLS don't need it, and nothing changes in `dub.json`:

- **Linux:** usually installed already (`libssl3` or `openssl` package).
- **macOS:** `brew install openssl@3`.
- **Windows:** `libssl-3-x64.dll` and `libcrypto-3-x64.dll` next to the program or in `PATH`, e.g. from an OpenSSL installer for Windows.

Call `loadOpenSsl()` at startup to fail early, or `loadOpenSsl(sslPath, cryptoPath)` to load specific files.

## Supported types

| ClickHouse | D column class | D value |
|---|---|---|
| `UInt8`…`UInt64`, `Int8`…`Int64` | `UInt8Column`…`Int64Column` | `ubyte`…`long` |
| `Int128`, `UInt128`, `Int256`, `UInt256` | `Int128Column`…`UInt256Column` | `Int128`…`UInt256` (exact; convert to `BigInt` for arithmetic), or `std.bigint.BigInt` |
| `Float32`, `Float64` | `Float32Column`, `Float64Column` | `float`, `double` |
| `Decimal(P, S)`, `Decimal32(S)`…`Decimal256(S)` | `Decimal32Column`…`Decimal256Column` | `Decimal` (exact), `string`, `double` |
| `Bool` | `BoolColumn` | `bool` |
| `String`, `FixedString(N)` | `StringColumn`, `FixedStringColumn` | `string`, `ubyte[]` |
| `Date`, `Date32` | `DateColumn`, `Date32Column` | `Date` |
| `DateTime[(tz)]`, `DateTime64(p[, tz])` | `DateTimeColumn`, `DateTime64Column` | `SysTime` |
| `UUID` | `UUIDColumn` | `UUID` |
| `IPv4`, `IPv6` | `IPv4Column`, `IPv6Column` | `IPv4`, `IPv6` (also `string`; `uint` for IPv4) |
| `Enum8`, `Enum16` | `Enum8Column`, `Enum16Column` | label `string`, or a D `enum` |
| `Nullable(T)` | `NullableColumn` | `Nullable!T` |
| `Array(T)`, nested too | `ArrayColumn` | `T[]` (e.g. `long[]`, `string[][]`, `Nullable!int[]`) |
| `Tuple(T1, ...)`, named too | `TupleColumn` | a struct or `std.typecons.Tuple` (by element name if named, else by position) |
| `Map(K, V)` | `MapColumn` | `V[K]`, or `Tuple!(K, V)[]` to keep order and repeated keys |
| `Point`, `Ring`, `LineString`, `MultiLineString`, `Polygon`, `MultiPolygon` | `TupleColumn`, `ArrayColumn` | `GeoPoint`, `GeoPoint[]`, `GeoPoint[][]`, `GeoPoint[][][]` |
| `LowCardinality(T)`, also in arrays | `LowCardinalityColumn`; `block.column!StringColumn(...)` etc. return its decoded values | as for `T` |

## Limitations

- TLS needs the system's OpenSSL; on macOS that is Homebrew's (the built-in LibreSSL is not used).
- Not supported yet: `Variant`/`Dynamic`/`JSON` (and the `Geometry` type built on Variant), `BFloat16`, `Time`/`Time64`. A query returning such a column fails with a clear error. Progress: [#10](https://github.com/buggins/clickhoused/issues/10).
- On Windows, timezone names fall back to UTC (no system timezone database). The point in time stays correct.

## Building and testing

```sh
dub build                                     # library
dub test                                      # unit tests, no server needed
CLICKHOUSE_HOST=localhost:9000 dub run :integration-tests-phobos   # integration tests, threads
CLICKHOUSE_HOST=localhost:9000 dub run :integration-tests-vibe     # integration tests, vibe.d fibers
```

To run the integration tests over TLS, start a test server with `sh integration-tests/tls/start-server.sh`; the script's header shows the environment variables to set.

API documentation: [clickhoused.dpldocs.info](https://clickhoused.dpldocs.info/). See [CONTRIBUTING.md](CONTRIBUTING.md). Changes are listed in [CHANGELOG.md](CHANGELOG.md), and third-party code in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[Boost Software License 1.0](LICENSE).

This is an unofficial project. It is not affiliated with or endorsed by ClickHouse, Inc. ClickHouse is a trademark of ClickHouse, Inc.
