# AGENTS.md

Guidance for AI coding agents working on **clickhoused**, a native D client library for ClickHouse.

## Project at a glance

- **What:** a pure-D client (connector) for ClickHouse over the **native TCP protocol** (port 9000; 9440 with TLS). It will be published on code.dlang.org as the dub package `clickhoused`. That name was confirmed free on 2026-10-29, and no other ClickHouse package exists on dub.
- **Repo:** `git@github.com:buggins/clickhoused.git`, default branch `main`. The author is Vadim Lopatin (GitHub `buggins`), who also maintains ddbc.
- **License:** BSL-1.0 (Boost), the same as Phobos, ddbc and mysql-native. This was decided on 2026-10-29. It could still change while the author is the sole contributor; see "Licensing rules" below.
- **Status:** 0.1.0 released on 2026-10-29 (tag `v0.1.0`), listed on code.dlang.org (https://code.dlang.org/packages/clickhoused), docs on https://clickhoused.dpldocs.info/. 0.2.0 (TLS) prepared on 2026-10-31.
  - New releases: update the version constants in `source/clickhoused/package.d` and `CHANGELOG.md`, then push a `vX.Y.Z` tag (the registry picks it up). Tag and publish only when the user asks.
- **`PLAN.md` (local and optional):** the detailed design plan is kept as a local, untracked file. It is excluded through `.git/info/exclude` and is not part of the repository, so it may be missing in your checkout.
  - If it is present, read it before making design-level changes and keep it up to date when a design decision changes. Never `git add` it.
  - If it is absent, this file is the reference. The `§` numbers below point to PLAN.md sections and can be ignored.

## Key design rules

1. **Pure D.** The wire protocol, column codecs, LZ4 and CityHash are written in D. C libraries are allowed **only** as optional extras, and the default build has zero dependencies:
   - ZSTD: behind the `zstd` dub configuration, linked at build time.
   - OpenSSL (TLS): **loaded at run time** by our own loader (`dlopen`/`LoadLibrary` from druntime) when the first secure connection is made. It uses our own minimal declarations, with no binding package and no bundled DLLs. If it can't be loaded, only secure connections fail, with a clear `ClientException`.
2. **CityHash must be v1.0.2**, the version ClickHouse uses for compressed-block checksums. The current CityHash gives different results. Validate against vectors produced by ClickHouse.
3. **Dual I/O, thread and fiber (§4):**
   - `vibe-core` is an **optional** dependency. All vibe code sits under `version(Have_vibe_core)`. TLS doesn't use `vibe-stream:tls`: one OpenSSL decorator over memory BIOs serves both modes. Docs builds use `version(ClickHouseDocs)`.
   - Anything that can block (connect/DNS, socket I/O, timeouts, locks, semaphores, sleep) must go through `IoBackend` / `Transport`. **Never call `std.socket`, `core.sync`, `Thread.sleep` or vibe APIs directly from protocol, connection or pool code.**
   - The default `IoMode.auto_` selects vibe only when the call runs inside a vibe task, otherwise Phobos.
   - Use runtime interfaces, not templates. `Connection` stays a single non-templated class, which ddbc depends on.
4. **Connection invariants (§4.5):**
   - One query at a time; a busy flag throws on concurrent use.
   - A result holds the connection until it is drained or closed.
   - Cancel is the only operation allowed from another thread or task.
   - Any broken stream poisons the connection, which is never returned to the pool.
   - In fiber mode a connection is bound to the thread that created it.
5. **Revision-gated protocol fields:** every field that depends on the negotiated protocol revision must be guarded with an explicit `if (revision >= Revision.withXxx)` check (constants are in `protocol/codes.d`). Verify each one against ClickHouse `src/Core/ProtocolDefines.h`. A mistake desynchronizes the stream silently.
   - The client speaks revision **54460** (`Revision.client`, the same as clickhouse-go). The effective revision is `min(client, server)`.
   - The server gates its Hello fields on the *client's* revision, so the client must gate everything on the effective revision.
   - 54460 deliberately stays below:
     - sparse serialization (54465);
     - chunked packets (54470);
     - the new String size-stream encoding (54492).
     Raising it means implementing every feature in between.
6. **ddbc compatibility (§7):** keep the dynamic per-cell access layer, the column metadata, `QueryStats`, `formatLiteral`, and `ConnectionOptions.fromParams(string[string])` working. The planned ddbc driver depends on all of them.
7. **Decoders must be robust.** Malformed or truncated input throws `ProtocolException`. Never crash, and never allocate based on an unchecked length.

## Licensing rules (important)

clickhoused must remain pure BSL-1.0 code written for this project.

- **Other ClickHouse clients are reference only. Never copy or translate their code.** This includes clickhouse-c, clickhouse-cpp, clickhouse-go/ch-go and the ClickHouse server, all Apache-2.0, as well as the MIT- and BSD-licensed clients. Read them to understand the protocol, then write original D code with its own structure, names and comments. Line-by-line translation (C→D, Go→D, ...) counts as copying. Wire-format facts (packet layouts, field order, constants, type encodings) are fine to reproduce.
- **Only exception: CityHash v1.0.2** (ported in M4 to `compress/cityhash.d`, listed in `THIRD_PARTY_NOTICES.md`). It is an exact algorithm, so a port is unavoidable. Port it from ClickHouse's `contrib/cityhash102`, which is MIT (Copyright 2011 Google). Keep Google's MIT copyright and permission notice at the top of `compress/cityhash.d`, and list it in a third-party notices file. Note that clickhouse-c's comment calls its CityHash a "v1.0.3 variant"; ClickHouse's own header says the code predates the 1.0.3 algorithm change. Trust ClickHouse's `contrib/cityhash102`.
- **Write LZ4 from the LZ4 block format specification**, not from the reference library.
- If any other third-party code ever seems necessary, **stop and ask the user first**.
- The README must say the project is unofficial and not affiliated with ClickHouse, Inc. ("ClickHouse" is their trademark).

## Layout

```
source/clickhoused/        library:
  package.d                public imports, version constants, clickhousedHasVibe
  connection.d             Connection (handshake, ping, query, exec, beginInsert, insert), QueryResult, QueryStats
  insert.d                 Inserter (addRow / addStruct / send / flush / finish / abort), appendValue, quoteIdentifier
  mapping.d                struct mapping: @column, @ignore, columnNames, readValue, RowRange (query!T)
  literal.d                formatLiteral (SQL literals)
  settings.d               ConnectionOptions (+ fromDsn, fromParams), HostPort, HostSelection
  pool.d                   ConnectionPool, PoolOptions (+ fromDsn), PooledConnection (RAII)
  exception.d              ClickHouseException > ServerException / ClientException / ConnectionException / ProtocolException
  block.d                  Block, readBlock / writeBlock (native format)
  io/                      transport.d (Transport interface), backend.d (IoMode, IoBackend, backendFor, inVibeTask),
                           phobos.d (thread-mode sockets), vibecore.d (fiber-mode sockets, Have_vibe_core only),
                           buffer.d (BufferedReader/Writer, varint/LE/string), mock.d,
                           openssl.d (run-time OpenSSL loader and function table), tls.d (TlsTransport, TlsContext;
                           test certificates in testdata/, regenerated by testdata/make-test-certs.sh)
  protocol/                codes.d (packet codes, Revision constants), packets.d (Hello, Query, Exception, Progress, ...),
                           testserver.d (ScriptedServer: scripted mock server for unit tests, unittest builds only)
  types/                   column.d (Column base: typed getters, FixedColumn!T), factory.d (createColumn), array.d (ArrayColumn),
                           numeric.d, string.d, datetime.d (+ resolveTimeZone), misc.d (UUID, Enum, Nullable, Nothing),
                           parser.d (type-name parser), package.d (imports all)
  compress/                cityhash.d (CityHash v1.0.2 port, MIT), lz4.d (LZ4 block codec), zstd.d (libzstd binding,
                           `zstd` configuration only), frame.d (Compression enum, frames, CompressedInput/Output)

integration-tests/         shared harness (dub subpackage `clickhoused:integration-tests`).
                           Tests are listed in `allTests` in source/integrationtests/harness.d.
integration-tests-phobos/  runner for thread mode
integration-tests-vibe/    runner for fiber mode: depends on vibe-core and runs the tests inside a vibe task
integration-tests-vibe1/   the same fiber-mode tests against vibe-core 1.22.6 (sources shared with integration-tests-vibe)
examples/                  dub subpackages: basic (`:example-basic`), vibe (`:example-vibe`); read CLICKHOUSE_DSN
bench/                     (planned) benchmarks
```

To add an integration test, write a `void function()` that throws on failure in an `integrationtests.*` module, and append it to `allTests` (set `needsServer` if it talks to ClickHouse). Mode-specific tests are registered by the runners:
- `threadTests` in `integration-tests-phobos/source/app.d`;
- `vibeTests` in `integration-tests-vibe/source/vibetests.d` (these may import vibe-core). Both runners then pick it up. Server tests use `connectToServer()` from `integrationtests.server`, and the `firstBlock()` helper in `integrationtests.basic`.

The root `/docs/` folder is generated API documentation (`dub build -b docs`) and is git-ignored. Hand-written documentation goes to `doc/`.

Other files:
- `.github/workflows/ci.yml`: CI with three jobs.
  - `test`: Linux/Windows/macOS × DMD/LDC, plus the minimum frontend 2.097.
  - `integration`: a ClickHouse service container for 23.8, 25.8, 26.8 and latest.
  - `lint`: dscanner, dfmt and the docs build.
- `.editorconfig`: editor and dfmt settings.
- `CONTRIBUTING.md`: contributor rules, including licensing.

## Local environment

- WSL2 Linux. The compiler is **LDC 1.36.0** (`ldc2`, frontend 2.106); **DMD is not installed**. DUB 1.36.0.
- The target minimum D frontend is **2.097**, the same as ddbc. ddbc depends on clickhoused, and dub enforces the compiler requirements of the dependencies of *all* configurations, so a higher minimum here would break every ddbc build on older compilers. Don't use language or Phobos features newer than 2.097 without the user's agreement. For example, `std.logger` is 2.101+, so fall back to `std.experimental.logger`.
  - Old frontends warn about things newer compilers accept, notably unreachable statements after a `throw` in a `version`/`else` branch, and dub turns warnings into errors.
  - Before pushing, build and test with LDC 1.27.1: download `https://github.com/ldc-developers/ldc/releases/download/v1.27.1/ldc2-1.27.1-linux-x86_64.tar.xz` into the scratchpad, then run dub with `--compiler=<path>/bin/ldc2`.
- A **ClickHouse 26.11 server runs locally**:
  - native protocol `localhost:9000`, HTTP `localhost:8123`;
  - user `default` with no password;
  - **server timezone `Europe/Lisbon`**, not UTC, which helps exercise DateTime timezone handling.
- A **ClickHouse 23.8 container** (the oldest supported version) for compatibility checks:
  - start it with `docker start clickhoused-ch23`; run tests with `CLICKHOUSE_HOST=localhost:19000`;
  - if it's missing, create it with `docker run -d --name clickhoused-ch23 -p 19000:9000 -e CLICKHOUSE_SKIP_USER_SETUP=1 clickhouse/clickhouse-server:23.8`.
  - Old servers type literals more strictly. For example, `[-1, 0, 1761741296789]` fails on 23.8 (no common supertype), so build such values with `toInt64(arrayJoin(['-1', ...]))`.
- The `clickhouse` binary (26.2) is available for `clickhouse client` and `clickhouse local`. It is handy for producing golden data, e.g. `clickhouse client -q "SELECT ... FORMAT Native" > file.bin`. Docker is available for testing other server versions with the `clickhouse/clickhouse-server` images.

## Commands

The package recipe format is **`dub.json`**, matching the author's other packages (ddbc, hibernated). Don't use `dub.sdl`, and never the legacy name `package.json`. Each subpackage (`integration-tests*`, `examples/*`) gets its own `dub.json` in its directory, listed in the root `subPackages` array by path.

```sh
dub build                                     # library, thread mode only (no dependencies)
dub test                                      # unit tests (no server needed)
dub run :integration-tests-phobos             # integration tests, threads
dub run :integration-tests-vibe               # integration tests, vibe.d fibers (downloads vibe-core on first run)
CLICKHOUSE_HOST=localhost:9000 dub run :integration-tests-phobos   # also run tests that need a server
CLICKHOUSE_COMPRESSION=lz4 ...                # run the whole suite with network compression (none/lz4/zstd)
dub test -c zstd                              # unit tests including the libzstd binding

dub run dscanner@0.15.2 -- --styleCheck .                 # lint (CI fails on any warning)
dub run dfmt@0.15.2 -- --inplace $(git ls-files '*.d')    # format (CI fails if this changes files)
dub build -b docs                                         # generate API docs into /docs/
```

Run the lint and format commands before committing D code. The tool versions are pinned so CI results stay stable. dfmt 0.15.2 mangles lambdas with attributes (`() nothrow {` becomes `() nothrow{`), so use named nested functions instead. It also merges `@safe return` into `@safereturn`; avoid the `return` attribute. dfmt sometimes needs two passes to settle; run it twice when it changes files.

Notes:
- `vibe-core` is an **optional** dependency of the root package, so a plain `dub build` never includes it.
- `dub.selections.json` files are git-ignored. A root `dub.selections.json` that lists vibe-core would silently enable vibe support in root builds, so never commit one.
- The vibe runner keeps its own selections file in `integration-tests-vibe/`, which keeps the root build free of vibe.
- vibe-core 2.14 prints many `@safe` deprecation warnings from its own sources under LDC 1.36. They come from vibe-core itself and are harmless.

## Related local repositories (read-only references)

- `../mysql-native`: the model for dual Phobos/vibe I/O. Key files:
  - `source/mysql/protocol/sockets.d` (socket interface with two implementations);
  - `source/mysql/impl/connection.d` (runtime socket-type selection, `openSocket` callback);
  - `source/mysql/impl/pool.d` (a vibe-only pool, a limitation we avoid);
  - `integration-tests*/` (the shared harness plus two runners).
- `../ddbc`: the author's JDBC-like DB abstraction; clickhoused gets a driver for it later (milestone M6). Key files:
  - `source/ddbc/core.d` (Driver, Connection, Statement, ResultSet, DialectType);
  - `source/ddbc/common.d` (DriverFactory, pool);
  - `source/ddbc/drivers/mysqlddbc.d` (the closest model).
  - Known hazard there: the per-connection `core.sync.mutex.Mutex` is recursive and owned by a thread, so it does not protect against two vibe fibers on one thread. The ClickHouse driver must use the lock that clickhoused provides for the active I/O mode.
- `../hibernated`: the author's Hibernate-like ORM built on ddbc. A ClickHouse dialect is planned after the ddbc driver (milestone M7). Key files:
  - `source/hibernated/dialect.d` (the abstract `Dialect`);
  - `source/hibernated/dialects/*.d` (MySQL, PostgreSQL, SQLite);
  - `source/hibernated/metadata.d` (`getCreateTableSQL` hardcodes `CREATE TABLE` without a dialect hook);
  - `source/hibernated/session.d` (`beginTransaction` calls `setAutoCommit(false)`).
  - ClickHouse facts that shape the dialect (checked on 26.2):
    - CREATE TABLE needs `ENGINE = MergeTree ORDER BY ...`;
    - `UPDATE` works only with `SETTINGS enable_block_number_column=1, enable_block_offset_column=1`;
    - `DELETE FROM` works on MergeTree;
    - transactions return `NOT_IMPLEMENTED`;
    - there is no auto-increment, and no foreign keys or unique indexes.
  - Driving clickhoused needs nothing hibernated-specific; everything goes through ddbc.

- `../../git/ClickHouse` (i.e. `/home/lve/git/ClickHouse`): a full clone of the ClickHouse repository. **Another agent uses it to work on ClickHouse issues.** Consult it whenever ClickHouse source is needed (protocol, serializations, compression), but follow these rules:
  - Never modify, check out, stash, clean, fetch or build anything there. The current branch and working tree belong to the other agent.
  - The working tree may be on the other agent's feature branch with unfinished edits. Read the upstream version with `git -C /home/lve/git/ClickHouse show origin/master:<path>`. Search it with `git -C /home/lve/git/ClickHouse grep <pattern> origin/master -- <paths>`.
  - Useful paths:
    - `src/Core/Protocol.h`, `src/Core/ProtocolDefines.h` (packet codes, revision constants);
    - `src/Server/TCPHandler.cpp`, `src/Client/Connection.cpp` (both sides of the protocol);
    - `src/DataTypes/Serializations/` (column wire formats);
    - `src/Compression/` (compressed-block framing, LZ4/ZSTD codecs);
    - `contrib/cityhash102/` (the exact CityHash v1.0.2 used for checksums).

Don't modify any of these repositories unless the user explicitly asks.

## External references

- ClickHouse sources: https://github.com/ClickHouse/ClickHouse. A local clone is available; see "Related local repositories" above.
- Native protocol docs: https://clickhouse.com/docs/en/native-protocol/basics
- Reference clients: clickhouse-cpp, clickhouse-go v2 / `ch-go` (cleanest low-level code), clickhouse-rs / klickhouse.
- vibe-core 2.14:
  - `vibe.core.net` (`connectTCP`, `TCPConnection`)
  - `vibe.core.sync` (`TaskMutex`, `LocalTaskSemaphore`, `TaskCondition`)
  - `vibe.core.core` (`runTask`, `sleep`, `yield`, `Task.getThis`)

## Protocol behaviour learned from the real server

- A `QueryResult` keeps the connection busy until it is exhausted or `close()`d. Taking `.front` alone is not enough.
- After most `ServerException`s the connection stays usable. Errors the server detects while still reading the Query packet (unknown setting name, unparsable setting value) are different: the server closes the connection right after sending the exception, and the next call fails with `ConnectionException`.
- Settings are sent with the IMPORTANT flag, so unknown names fail with code 115 instead of being silently ignored.
- Profile-event blocks (`String`, `DateTime`, `UInt64`, `Enum8`, `Int64` columns) arrive with every query at revision ≥ 54451, so their column types must always be decodable.
- `getSetting()` returns the narrowest integer type (e.g. `UInt8`), not `UInt64`.
- **INSERT flow:**
  1. The client sends the query (`INSERT INTO t (a, b) VALUES`) plus an empty block.
  2. The server replies with `TableColumns` (optional), then a header Data block with the expected names and types.
  3. The client sends Data blocks, then an empty block, which ends the data. Never send a 0-row block in the middle: it ends the insert.
  4. The server replies with `EndOfStream` or `Exception`.
- **The server sends profile events after every block the client sends.** The inserter drains pending packets after each block (`Transport.dataAvailable`); otherwise both sides can block on full socket buffers.
- **After an `Exception` during an insert,** the server discards client data until the empty end block arrives. The client must send that block if it hasn't already, or the connection stays desynchronized.
- **Native inserts get no Progress packets**, so `Inserter.finish` reports `writtenRows = rowsSent`. Inline `INSERT ... VALUES (...)` and `INSERT ... SELECT` do report progress, and run fine through `exec()`.
- **A `TableColumns` packet means the server is waiting for data** (an INSERT, or the `input()` function). `query()`/`exec()` end such an insert with no rows and throw a `ClientException`.
- **Raise errors where the stream is still intact outside `Connection.guarded`.** `guarded` closes the connection on any non-server exception.
- **Network compression** (`ConnectionOptions.compression`):
  - The Query packet carries a compression flag. The client also sends `network_compression_method`, so the server compresses its replies with the same method.
  - Only the block part of Data, Totals and Extremes packets is compressed, in both directions. Packet codes and table names are not.
  - At our revision, profile events and log blocks stay uncompressed; they are compressed only from revision 54481.
  - Each block ends at a frame boundary, and `readDataBlock` checks this.
  - All client Data packets are compressed, including the empty end-of-data blocks. Use `Connection.blockReader`/`blockWriter`, `readDataBlock`, `writeEndOfData` and `flushBlock`; never write blocks to `writer` directly.
  - The server may send method NONE (`0x02`) frames even with compression on.
- **Thread/fiber mode (M5a):**
  - `IoMode.auto_` picks the vibe backend only inside a vibe.d task (`inVibeTask()`); `Connection.ioBackend` reports the choice.
  - `VibeTransport` maps end of stream to `read() == 0`, timeouts to `ConnectionException`, and lets vibe's `InterruptException` propagate unchanged (the connection is then closed).
  - A fiber-mode connection is bound to its thread; use from another thread throws `ClientException`.
  - `yieldBetweenBlocks` calls `IoBackend.yieldNow()` after each received block.
- **Cancel:**
  - `Connection.cancel()` writes the 1-byte Cancel packet straight to the transport. It's safe from another thread/task while a result is being read, and refused during an insert.
  - The server answers a cancel with `EndOfStream` and ignores a Cancel that arrives when no query is running.
  - `QueryResult.close()` cancels and discards (server errors ignored); `QueryResult.drain()` reads to the end without cancelling. `exec()` uses `drain()`: never cancel a DDL statement.
- **Connection strings and failover (M5b):**
  - DSN: `clickhouse://user:pass@h1:9000,h2/db?param=...`. Known parameters are options; `pool_*` parameters are for `PoolOptions.fromDsn`; anything else becomes a server setting.
  - `secure`/`tls` turn on TLS (`ConnectionOptions.secure`, `tls`: CA file, client certificate, server name, `skip_verify`). The port defaults to 0, meaning 9000, or 9440 with TLS; `Connection.host` reports the port in use.
  - Connecting tries each host: network and protocol errors move to the next host, a server-rejected login doesn't. `Connection.host` reports the chosen host.
- **Connection pool (M5b):**
  - Thread mode: one shared `SubPool` (`ThreadPoolSync`: mutex and condition).
  - Fiber mode: one `SubPool` per thread (`FiberPoolSync`: no-op lock and a vibe manual event, since tasks on a thread don't preempt each other), chosen by `IoMode` like connections.
  - Expiry and health checks are lazy, on acquire/release; never do I/O while holding the lock.
  - Returned connections that are closed, busy or too old are closed, not reused.
- **Struct mapping (M5c):**
  - `Connection.query!T`/`queryRow!T`/`queryValue!T`/`insert(table, range)` are member templates. UFCS can't add them, because a member named `query` hides free functions.
  - Fields map by name (`@column`, `@ignore`), and extra result columns are ignored.
  - `readValue!T` is the read-side counterpart of `appendValue`.
  - A failed column binding closes the result, so the connection doesn't stay busy.
  - `insert(table, structs)` aborts (closes the connection) when a value doesn't fit.
- **vibe-core versions:** the optional dependency accepts `>=1.22.0 <3.0.0`.
  - Downstream projects (ddbc's example) pin vibe-core 1.x, and dub activates an optional dependency whenever the root has it, so a too-narrow range breaks *their* dependency resolution.
  - `:integration-tests-vibe1` runs the vibe tests against vibe-core 1.22.6; `vibecore.d` must compile with both 1.x and 2.x.
- **TLS** (`io/tls.d`): `TlsTransport` wraps the raw transport in `Connection.connectTo`; `TlsContext.client` is fetched once before the host loop, so a missing OpenSSL or a bad certificate file fails immediately with a `ClientException`, while handshake and verification failures are `ConnectionException`s that move on to the next host.
  - Integration tests over TLS: `sh integration-tests/tls/start-server.sh [tag] [port] [name]` starts a ClickHouse container with TLS on 9440 (mapped to 19440 by default) using the certificates in `source/clickhoused/io/testdata`; then set `CLICKHOUSE_SECURE=1`, `CLICKHOUSE_TLS_CA`, `CLICKHOUSE_TLS_DIR` and `CLICKHOUSE_TLS_CERT_USER=cert_user` (see `integrationtests.server`). The whole suite then runs encrypted, plus the `needsTls` tests.
  - On Windows, closing a socket with unread data resets the connection, which can discard data in transit (a close_notify included).
  - Trusted CAs without `tls.caFile`: OpenSSL's default paths, plus on Windows the `ROOT` system store imported through crypt32. macOS needs Homebrew's `openssl@3`; the system LibreSSL is not used.
  - Unit-test switches: `CLICKHOUSED_REQUIRE_OPENSSL=1` turns "OpenSSL not found" from a skip into a failure; `CLICKHOUSED_TLS_PUBLIC_HOST=github.com:443` verifies a public server with the system trust store (needs the internet). CI sets both on every OS.
- **ZSTD** is optional. The `zstd` dub configuration defines `version (ClickHousedZstd)` and links `libzstd`. Test it with:
  - `dub test -c zstd`;
  - `CLICKHOUSE_COMPRESSION=zstd dub run :integration-tests-phobos --override-config=clickhoused/zstd`.

## Initial type scope

The first implementation supports **basic types only**:
- `(U)Int8`–`(U)Int64`, `Float32`/`Float64`, `Bool`;
- `String`, `FixedString(N)`;
- `Date`, `Date32`, `DateTime[(tz)]`, `DateTime64(p[, tz])`;
- `UUID`, `Enum8`/`Enum16`;
- `Nullable(T)` of the types above.

`Array(T)` is supported too (#1). Everything else comes later (tracking issue #10):
- Tuple, Map, LowCardinality;
- Decimal, Int/UInt128/256, IPv4/IPv6;
- Geo types, Variant/Dynamic/JSON.

These types are implemented (milestone M2). An unsupported type must fail with a clear `ClientException` that names the type, never with a desynchronized stream.

Column conventions:
- Every column keeps its values raw, as on the wire, in a public array (`data`, or `bytes` for FixedString), and converts on access. For example, `DateTimeColumn.data` is `uint[]` epoch seconds, and `opIndex` returns a `SysTime`.
- Every column implements the base `Column` getters that make sense for it: `getLong`, `getUlong`, `getDouble`, `getBool`, `getString`, `getBytes`, `getDate`, `getSysTime`, `getUUID`, `getVariant`, `isNull`. The others throw `ClientException`.
- `getString` must produce exactly the server's `toString()` text. The integration tests check this against the server.
- Wrap values in a `Variant` with `makeVariant`. It strips `const`, so `get!T` works, and confines the `@trusted` code to one place.
- DateTime columns without a timezone parameter get the server timezone from the handshake.
- Timezones are resolved with `PosixTimeZone`. On Windows, which has no tz database, they fall back to UTC: the point in time stays correct, only the presentation differs.
- Every column has `getQuotedString`, its value as ClickHouse writes it inside an array (`'...'` with backslash escapes for strings, dates, times, UUIDs and enums; `NULL`; FixedString keeps its zero padding there, unlike `getString`). Columns opt in to quoting through `quotedInText`.
- Every column also implements the appenders that mirror the getters: `appendLong`, `appendUlong`, `appendDouble`, `appendBool`, `appendString` (parses non-string types), `appendBytes`, `appendDate`, `appendSysTime`, `appendUUID`, `appendNull` (Nullable only), `appendDefault`, and `truncate`.
  - Conversions are range-checked, and a failed append must leave the column unchanged.
  - `appendString` for DateTime types parses the text in the column timezone.

Until LowCardinality is implemented, the client sends the setting `low_cardinality_allow_in_native_format=0`. With it, the server converts `LowCardinality(T)` columns to plain `T`, so those tables stay readable.

## Conventions

These are proposed; refine them when code lands.

- Module names: `clickhoused.<area>.<name>`. Public API is re-exported from `clickhoused/package.d`.
- Use `@safe` by default, with small `@trusted` blocks only in the I/O and reinterpret-cast hot paths, each with a comment explaining why it is safe.
- **Every public symbol gets a Ddoc comment** (`///` or `/++ ... +/`), following common D library practice. Docs are generated on dpldocs.info, and dscanner flags undocumented public declarations. Use the standard Ddoc sections where useful (`Params:`, `Returns:`, `Throws:`, `See_Also:`), and `/// ditto` for groups.
- **Put small unit tests inside modules**, next to the code they test. A `///` documented unittest right after a public symbol becomes its usage example in the docs; prefer that for public API. Plain `unittest` blocks are fine for internal details.
- Every column type needs a golden-bytes unit test and an INSERT→SELECT round-trip integration test in **both** I/O modes. Cover NULLs, empty arrays, extreme values and non-UTC timezones.
- Commit only when the user asks.
- Work goes through GitHub issues and pull requests: each feature or fix has an issue, is developed on a feature branch, and lands through a PR that says `Closes #N`. The author merges; releases and tags only on request.
- Follow the milestone order:
  - M0: scaffold (done);
  - M1: wire, Phobos backend, first query (done);
  - M2: read **basic types only** (see "Initial type scope" below) (done);
  - M3: insert (done);
  - M4: LZ4/ZSTD compression (done);
  - M5: high-level API, vibe backend and pool → **0.1.0** on code.dlang.org (done, released);
  - M6: ddbc driver (done, in ddbc 0.8.0);
  - M7: hibernated dialect (hibernated PR #99);
  - M8: TLS (done, 0.2.0), composite types and production features;
  - M9: Variant/Dynamic/JSON → 1.0.
