# Changelog

All notable changes to this project are documented here. The project follows [Semantic Versioning](https://semver.org); until 1.0, minor versions may change the API.

## Unreleased

### Added
- **`Array(T)`** for all supported element types, nested arrays and `Array(Nullable(T))` (#1). `ArrayColumn` keeps the offsets and the element column as on the wire; `getString` matches the server's `toString()`.
- D arrays map to `Array` columns in struct mapping, `readValue`, `Inserter.addRow`/`addStruct` and `Connection.insert` (`long[]`, `string[][]`, `Nullable!int[]`, ...). Array text such as `[1, 2]` or `['a', NULL]` is accepted too.
- `Column.getQuotedString`: a value as ClickHouse writes it inside an array.
- **Native `LowCardinality(T)`** (#2), including `LowCardinality(Nullable(T))` and LowCardinality inside arrays: dictionary-encoded on the wire in both directions, decoded into a plain column of type `T` (`LowCardinalityColumn.values`). The client no longer sends `low_cardinality_allow_in_native_format=0`, which made the server convert such columns.
- `Column.appendFrom` copies a value between columns of the same type; `Column.readStatePrefix`/`writeStatePrefix` handle per-column serialization state.

### Changed
- `LowCardinality(T)` columns now arrive with their real type name (`LowCardinality(String)`, not `String`) as a `LowCardinalityColumn`. `Block.column!StringColumn("name")` and the other typed accessors still work: for such a column they return the decoded values. Code that casts `block.columns[i]` directly to the plain column class needs `LowCardinalityColumn.values`.

## 0.2.0 — 2026-10-31

### Added
- **TLS** in thread and fiber mode: `ConnectionOptions.secure` and `tls` (`TlsOptions`), or `secure=true` in the connection string, with `skip_verify`, `tls_ca_file`, `tls_cert_file`, `tls_key_file` and `tls_server_name`. The server certificate and host name are verified by default (TLS 1.2 or newer); client certificates allow certificate-based login.
- OpenSSL 1.1.1 or 3.x is loaded at run time when the first secure connection is made, so builds without TLS don't need it and `dub.json` needs no change. `loadOpenSsl` loads it early or from specific files; `openSslLibrary` tells which file was loaded.
- Trusted certificates come from the system: OpenSSL's default store, plus the Windows certificate store on Windows. macOS needs Homebrew's `openssl@3`.
- `Connection.tlsVersion`.
- CI runs the whole integration suite over TLS against every tested ClickHouse version (23.8 to latest), in thread and fiber mode.

### Changed
- `ConnectionOptions.port` and `HostPort.port` default to 0, meaning 9000, or 9440 with TLS. A connection string without a port gives 0 too. `Connection.host` reports the port actually used.

## 0.1.2 — 2026-10-29

### Changed
- The optional vibe-core dependency now accepts vibe-core **1.22 and newer** (`>=1.22.0 <3.0.0`), not only 2.x. A project that pins vibe-core 1.x (such as ddbc's example) failed to resolve its dependencies as soon as clickhoused was in its dependency graph, even without using it.
- CI runs the vibe.d integration tests against vibe-core 1.22.6 too (`:integration-tests-vibe1`).

## 0.1.1 — 2026-10-29

### Changed
- The minimum D frontend is now **2.097** (DMD 2.097+, LDC 1.27+, GDC 12+), the same as ddbc, instead of 2.105. This lets ddbc offer a ClickHouse driver without raising its own minimum compiler.
- Logging falls back to `std.experimental.logger` on compilers without `std.logger`.

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
