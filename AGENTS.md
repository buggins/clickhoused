# AGENTS.md

Guidance for AI coding agents working on **clickhoused**, a native D client library for ClickHouse.

## Project at a glance

- **What:** a pure-D client (connector) for ClickHouse over the **native TCP protocol** (port 9000; 9440 with TLS). It will be published on code.dlang.org as the dub package `clickhoused`. That name was confirmed free on 2026-10-29, and no other ClickHouse package exists on dub.
- **Repo:** `git@github.com:buggins/clickhoused.git`, default branch `main`. The author is Vadim Lopatin (GitHub `buggins`), who also maintains ddbc.
- **License:** BSL-1.0 (Boost), the proposed default.
- **Status:** planning phase. Do not start implementation work unless the user asks for it.
- **`PLAN.md` (local and optional):** the detailed design plan is kept as a local, untracked file. It is excluded through `.git/info/exclude` and is not part of the repository, so it may be missing in your checkout.
  - If it is present, read it before making design-level changes and keep it up to date when a design decision changes. Never `git add` it.
  - If it is absent, this file is the reference. The `§` numbers below point to PLAN.md sections and can be ignored.

## Key design rules

1. **Pure D.** The wire protocol, column codecs, LZ4 and CityHash are written in D. C libraries (ZSTD, OpenSSL) are allowed **only** behind optional dub dependencies or configurations. The default build has zero dependencies.
2. **CityHash must be v1.0.2**, the version ClickHouse uses for compressed-block checksums. The current CityHash gives different results. Validate against vectors produced by ClickHouse.
3. **Dual I/O, thread and fiber (§4):**
   - `vibe-core` is an **optional** dependency. All vibe code sits under `version(Have_vibe_core)`, and TLS in fiber mode under `version(Have_vibe_stream_tls)`. Docs builds use `version(ClickHouseDocs)`.
   - Anything that can block (connect/DNS, socket I/O, timeouts, locks, semaphores, sleep) must go through `IoBackend` / `Transport`. **Never call `std.socket`, `core.sync`, `Thread.sleep` or vibe APIs directly from protocol, connection or pool code.**
   - The default `IoMode.auto_` selects vibe only when the call runs inside a vibe task, otherwise Phobos.
   - Use runtime interfaces, not templates. `Connection` stays a single non-templated class, which ddbc depends on.
4. **Connection invariants (§4.5):**
   - One query at a time; a busy flag throws on concurrent use.
   - A result holds the connection until it is drained or closed.
   - Cancel is the only operation allowed from another thread or task.
   - Any broken stream poisons the connection, which is never returned to the pool.
   - In fiber mode a connection is bound to the thread that created it.
5. **Revision-gated protocol fields:** every field that depends on the negotiated protocol revision must be guarded with an explicit `if (revision >= DBMS_MIN_...)` check. Verify each one against ClickHouse `src/Core/ProtocolDefines.h`. A mistake desynchronizes the stream silently.
6. **ddbc compatibility (§7):** keep the dynamic per-cell access layer, the column metadata, `QueryStats`, `formatLiteral`, and `ConnectionOptions.fromParams(string[string])` working. The planned ddbc driver depends on all of them.
7. **Decoders must be robust.** Malformed or truncated input throws `ProtocolException`. Never crash, and never allocate based on an unchecked length.

## Planned layout

The layout is planned, not created yet:

```
source/clickhoused/      library (io/, compress/, protocol/, types/, connection.d, pool.d, ...)
integration-tests/       shared integration test harness (dub subpackage)
integration-tests-phobos/  runner for thread mode
integration-tests-vibe/    runner for fiber mode (depends on vibe-core)
examples/                one dub subpackage per example
bench/                   benchmarks
```

Note: `.gitignore` currently ignores every `docs/` directory, which is dub's generated docs output. Don't put hand-written docs there until that entry is narrowed (a planned M0 task).

## Local environment

- WSL2 Linux. The compiler is **LDC 1.36.0** (`ldc2`, frontend 2.106); **DMD is not installed**. DUB 1.36.0.
- The target minimum D frontend is 2.105. Don't use language or Phobos features newer than that without the user's agreement.
- A **ClickHouse 26.11 server runs locally**:
  - native protocol `localhost:9000`, HTTP `localhost:8123`;
  - user `default` with no password;
  - **server timezone `Europe/Lisbon`**, not UTC, which helps exercise DateTime timezone handling.
- The `clickhouse` binary (26.2) is available for `clickhouse client` and `clickhouse local`. It is handy for producing golden data, e.g. `clickhouse client -q "SELECT ... FORMAT Native" > file.bin`. Docker is available for testing other server versions with the `clickhouse/clickhouse-server` images.

## Commands

These are the planned commands; update this section once `dub.sdl` exists.

```sh
dub build                                     # library, thread mode only
dub test                                      # unit tests (no server needed; MockTransport + golden bytes)
dub run :integration-tests-phobos             # integration tests, threads   (needs a server)
dub run :integration-tests-vibe               # integration tests, vibe.d fibers (needs a server)
CLICKHOUSE_HOST=localhost:9000 dub run ...    # server address for integration tests
```

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

Don't modify those repositories unless the user explicitly asks.

## External references

- ClickHouse sources:
  - `src/Core/Protocol.h`, `src/Core/ProtocolDefines.h`
  - `src/Server/TCPHandler.cpp`, `src/Client/Connection.cpp`
  - `src/DataTypes/Serializations/*`, `src/Compression/*`
- Native protocol docs: https://clickhouse.com/docs/en/native-protocol/basics
- Reference clients: clickhouse-cpp, clickhouse-go v2 / `ch-go` (cleanest low-level code), clickhouse-rs / klickhouse.
- vibe-core 2.14:
  - `vibe.core.net` (`connectTCP`, `TCPConnection`)
  - `vibe.core.sync` (`TaskMutex`, `LocalTaskSemaphore`, `TaskCondition`)
  - `vibe.core.core` (`runTask`, `sleep`, `yield`, `Task.getThis`)
  - `vibe-stream:tls` 1.5 for TLS.

## Conventions

These are proposed; refine them when code lands.

- Module names: `clickhoused.<area>.<name>`. Public API is re-exported from `clickhoused/package.d`.
- Use `@safe` by default, with small `@trusted` blocks only in the I/O and reinterpret-cast hot paths, each with a comment explaining why it is safe.
- Ddoc comments on every public symbol (docs are generated on dpldocs.info).
- Every column type needs a golden-bytes unit test and an INSERT→SELECT round-trip integration test in **both** I/O modes. Cover NULLs, empty arrays, extreme values and non-UTC timezones.
- Commit only when the user asks.
- Follow the milestone order:
  - M0: scaffold;
  - M1: wire, Phobos backend, first query;
  - M2: read all common types;
  - M3: insert;
  - M4: LZ4/ZSTD compression;
  - M5: high-level API, vibe backend and pool → **0.1.0** on code.dlang.org;
  - M6: ddbc driver;
  - M7: TLS and production features;
  - M8: Variant/Dynamic/JSON → 1.0.
