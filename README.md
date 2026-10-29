# clickhoused

[![CI](https://github.com/buggins/clickhoused/actions/workflows/ci.yml/badge.svg)](https://github.com/buggins/clickhoused/actions/workflows/ci.yml)
[![License: BSL-1.0](https://img.shields.io/badge/license-BSL--1.0-blue.svg)](LICENSE)

A native [ClickHouse](https://clickhouse.com) client library for the [D programming language](https://dlang.org).

> **Status: early development.** The project scaffold is in place, and the protocol implementation has not started yet. The API is not usable yet.

## Goals

- **Pure D.** It implements the ClickHouse **native TCP protocol** (port 9000) directly, with no C client library underneath.
- **Threads and fibers.** It works with blocking Phobos sockets in ordinary threads, and with [vibe.d](https://vibed.org) (vibe-core) sockets in fibers. vibe-core is an *optional* dependency: it is used only when your application depends on it.
- **Columnar and row APIs.** Fast block/column access for bulk work, plus mapping between D structs and rows, with results as ranges.
- **Streaming** for large SELECT results and batched INSERTs.
- Planned integration with [ddbc](https://github.com/buggins/ddbc) and [hibernated](https://github.com/buggins/hibernated).

The first releases will support basic column types: integers, floats, Bool, String, FixedString, Date/DateTime types, UUID, Enum and Nullable. Composite types such as Array, Tuple, Map and LowCardinality will follow.

## Building

You need a D compiler with frontend 2.105 or newer (DMD 2.105+, LDC 1.35+ or GDC 14+), and [dub](https://code.dlang.org).

```sh
dub build                           # build the library
dub test                            # run the unit tests
dub run :integration-tests-phobos   # integration tests, thread mode
dub run :integration-tests-vibe     # integration tests, vibe.d fiber mode
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[Boost Software License 1.0](LICENSE).

This is an unofficial project. It is not affiliated with or endorsed by ClickHouse, Inc. ClickHouse is a trademark of ClickHouse, Inc.
