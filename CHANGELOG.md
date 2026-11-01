# Changelog

All notable changes to this project are documented here. The project follows [Semantic Versioning](https://semver.org); until 1.0, minor versions may change the API.

## 0.5.0 — 2026-11-01

Variant, Dynamic and JSON (#29–#31, from the split of #9) and Nested (#22): with this release every column type of tracking issue #10 is supported. New types use the client-friendly native forms that recent servers offer, requested automatically (`ConnectionOptions.simpleNativeFormats`).

### Added
- **`Nested(...)` columns kept whole** (#22): with `flatten_nested = 0` a Nested column keeps its type `Nested(a T, b U)` and is read and written as an array of named tuples (on the wire it is exactly `Array(Tuple(a T, b U))`), so it maps to arrays of structs. With the default `flatten_nested = 1` the server splits it into the `Array` columns `n.a`, `n.b`, which already worked; struct fields map to them with `@column("n.a")`, and the server rejects rows whose arrays differ in length.
- **`Variant(T1, ..., Tn)`** (#29): `VariantColumn` keeps the discriminators and one column per alternative, as on the wire; getters and text go to the held value (`[1,'a',NULL]` inside arrays), and NULL is a row without a value. Appends choose the alternative from the kind of value (`appendLong` the first integer alternative it fits in, `appendString` a string alternative, else the first one that parses the text; `1` and `'1'` in text lists go to different alternatives); `appendTo` chooses explicitly. Arrays, structs, `Decimal`, `IPv4` and other values go to the alternative that takes them.
- **`Geometry`**, the Variant of the geo types (newer servers), and the **`MultiPoint`** geo type (`Array(Point)`).
- `std.variant.Variant` maps to any column in struct mapping, `readValue` and inserts (`appendVariant`): the value of `getVariant`, NULL as an empty `Variant`. `readValue` reads a Variant cell as the D type of its held value.

- **`Dynamic`** (#30): `DynamicColumn` keeps the values as a `VariantColumn` whose alternatives are the types of the block; `dynamicTypeName(row)` is the server's `dynamicType()`. On servers 25.6 and newer the connection asks for the flattened form (`output_format_native_use_flattened_dynamic_and_json_serialization`), so every value is readable; older servers (or `simpleNativeFormats = false`) send the V1 form, where values beyond `max_types` are binary-encoded: they can be copied to another table but reading one throws. Values are written in the V1 form, which every server accepts. Appends infer the type as the server does for inserted text (`Int64`, `UInt64`, `Float64`, `Bool`, `String`, `Date`/`Date32`, `DateTime`/`DateTime64(9)`, `UUID`); `appendValue` derives it from the D type (`Array(...)`, `Map(...)`, a named `Tuple` for a struct, `Decimal(P, S)`, `IPv4`, ...); `appendTyped` takes it explicitly.
- **`JSON`** (#31), as text: `JsonColumn` holds one JSON text per row, as the server's `toString()` writes it; inside arrays and tuples it is quoted like a string. On servers 24.10 and newer the connection asks for JSON as text (`output_format_native_write_json_as_string`), and the server accepts the same text on insert; reading the server's internal form (older servers, or the option off) fails with a clear `ClientException`. Appended text must be a JSON object and is checked with `std.json` first, because the server closes the connection when it can't parse the JSON of an insert. `std.json.JSONValue` maps to JSON columns (and JSON text in any column), also inside Variant and Dynamic. JSON type parameters (typed paths, `SKIP`, ...) are accepted and kept as text.
- `ConnectionOptions.simpleNativeFormats` (DSN `simple_native_formats`, default on): request the client-friendly native forms of new types from servers that have them (JSON as text from 24.10, flattened Dynamic from 25.6).
- The type parser accepts named parameters such as `max_types=2`.

### Changed
- `Connection.query!T`, `queryRow!T`, `queryValue!T`, `insert` and `RowRange` infer their attributes instead of being marked `@safe`, so structs with a `std.variant.Variant` field (whose copying is `@system`) work; for other structs they are still `@safe`. `appendValue` takes its value by `auto ref`.

## 0.4.0 — 2026-11-01

More column types (#19–#21 from the split of #8; tracking issue #10) and exact float text.

### Added
- **Geo types** (#19): `Point`, `Ring`, `LineString`, `MultiLineString`, `Polygon` and `MultiPolygon` are read and written as the Tuple and Array columns they are aliases of, keeping their type names. The `GeoPoint` value type maps to `Point`; arrays of it to the other geo types. `formatLiteral` writes `GeoPoint` as `CAST((x, y) AS Point)`.
- **`BFloat16`** (#20): `BFloat16Column` keeps the raw 16-bit values and reads them as `float`. Appended numbers are truncated to their upper 16 bits, exactly as the server converts them (it does not round to nearest). Maps to `float` in struct mapping and `readValue`. The type exists on newer servers (not on 23.8).
- **`Time` and `Time64(p)`** (#21): `TimeColumn` (seconds) and `Time64Column` (ticks of 10^-p seconds) keep the raw values; `getString` gives the server's text (`-01:01:01`, `999:59:59.999999`). The values are signed spans up to ±999:59:59, so they map to `core.time.Duration`; `std.datetime.TimeOfDay` works for values from 00:00:00 to 23:59:59. The types exist since ClickHouse 25.6; before 25.12 they need the `enable_time_time64_type` setting.
- New `Column` methods `getDuration` and `appendDuration` (for `Time` and `Time64`; passed on by `Nullable` and `LowCardinality`). Other columns throw `ClientException`, as for the other typed getters.

### Fixed
- `getString` of `Float32` and `Float64` values now gives the server's text (#24): the shortest decimal that reads back as the same value, in plain notation for decimal exponents from -6 to 21 and `1e21`-style otherwise. Before, it kept only 6 significant digits (`9.99922e+09` instead of `9999221000`), also inside arrays, tuples and maps.

## 0.3.0 — 2026-10-31

Composite and extended column types (tracking issue #10).

### Added
- **`Array(T)`** for all supported element types, nested arrays and `Array(Nullable(T))` (#1). `ArrayColumn` keeps the offsets and the element column as on the wire; `getString` matches the server's `toString()`.
- D arrays map to `Array` columns in struct mapping, `readValue`, `Inserter.addRow`/`addStruct` and `Connection.insert` (`long[]`, `string[][]`, `Nullable!int[]`, ...). Array text such as `[1, 2]` or `['a', NULL]` is accepted too.
- **Native `LowCardinality(T)`** (#2), including `LowCardinality(Nullable(T))` and LowCardinality inside arrays: dictionary-encoded on the wire in both directions, decoded into a plain column of type `T` (`LowCardinalityColumn.values`). The client no longer sends `low_cardinality_allow_in_native_format=0`, which made the server convert such columns.
- **`Int128`, `UInt128`, `Int256`, `UInt256`** (#4): value types that hold the numbers exactly as stored, with comparison and conversions to and from decimal text, `long`/`ulong`, `double`, `std.bigint.BigInt`, and `std.int128.Int128` on D frontends 2.100+. `std.bigint.BigInt` also maps to any integer column. `formatLiteral` writes them as `toInt128('…')` etc., because ClickHouse reads plain literals beyond 64 bits as `Float64`.
- **`Decimal(P, S)`** (#3), also as `Decimal32(S)`…`Decimal256(S)`: columns keep the scaled integers as on the wire (`int`, `long`, `Int128`, `Int256`). The `Decimal` value type holds a number exactly with its scale: text (`toString` as the server prints it, `toFixedString` with all digits), `double`, rescaling, numeric comparison; `unscaled.toBigInt()` for arithmetic. Text and doubles with more digits than the scale are truncated towards zero, as the server does; values beyond the precision are rejected. `formatLiteral` writes `toDecimal256('…', S)`.
- **`IPv4` and `IPv6`** (#5): columns and value types. `IPv4.value` is the address as a number (as in `std.socket.InternetAddress`), `IPv6.bytes` the 16 bytes in network order (as in `Internet6Address`). Text exactly as the server prints it (IPv6 zero compression, dotted IPv4-mapped and -compatible tails); IPv4 text given for IPv6 is stored IPv4-mapped, as the server does. `formatLiteral` writes `toIPv4('…')`/`toIPv6('…')`.
- **`Tuple(...)`** (#6), including named tuples: `TupleColumn` with one column per element, element access by index or name, text as the server prints it (`(1,'a')`), and tuple text in appends. D structs and `std.typecons.Tuple` map to tuple columns, in struct fields too: by element name when the tuple is named and has every field, otherwise by position. `formatLiteral` writes `std.typecons.Tuple` as `tuple(…)`.
- **`Map(K, V)`** (#7): `MapColumn`, kept as `Array(Tuple(K, V))` as on the wire (`entries`, `keys`, `values`), so LowCardinality keys and nested maps work. Text as the server prints it (`{'a':1,'b':2}`), map text in appends. `V[K]` associative arrays map to Map columns, and arrays of `Tuple!(K, V)` keep the order and repeated keys. `formatLiteral` writes associative arrays as `map(…)`.
- New `Column` methods: `getQuotedString` (a value as ClickHouse writes it inside an array), `appendFrom` (copies a value between columns of the same type), `readStatePrefix`/`writeStatePrefix` (per-column serialization state).

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
