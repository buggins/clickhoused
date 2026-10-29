# Changelog

All notable changes to this project are documented here. The project follows [Semantic Versioning](https://semver.org); until 1.0, minor versions may change the API.

## 0.1.0 — 2026-10-29

First public release.

### Protocol and I/O
- Native TCP protocol (revision 54460), supporting ClickHouse 23.8 and newer.
- Thread mode (blocking Phobos sockets) and vibe.d fiber mode (vibe-core sockets), selected automatically: fiber mode inside vibe.d tasks. vibe-core is an optional dependency.
- Connect, send and receive timeouts; query cancellation, also from another thread or task.
- LZ4 network compression in pure D; optional ZSTD via the system library (`zstd` dub configuration). Compressed blocks are verified with CityHash v1.0.2 checksums.

### Queries and inserts
- Streaming query results (`Connection.query`), `exec` for statements, server-side query parameters, per-connection and per-query settings.
- Progress, profile events and server log callbacks; query statistics.
- Streaming INSERT (`Connection.beginInsert` / `Inserter`) with automatic batching, and `Connection.insert` for blocks and structs.
- Struct mapping with `@column` and `@ignore`: `query!T`, `queryRow!T`, `queryValue!T`, inserting ranges of structs.
- `formatLiteral` for SQL literals; `quoteIdentifier`.

### Types
- `(U)Int8`–`(U)Int64`, `Float32`, `Float64`, `Bool`, `String`, `FixedString(N)`, `Date`, `Date32`, `DateTime[(tz)]`, `DateTime64(p[, tz])`, `UUID`, `Enum8`, `Enum16`, `Nullable(T)`.
- `LowCardinality(T)` columns are received as `T`.
- Typed per-cell getters and appenders with range-checked conversions on every column.

### Connections
- Connection strings (`clickhouse://user:pass@host1,host2/db?compress=lz4&max_threads=4`) and host failover.
- Connection pool for threads and vibe.d tasks.
