# Contributing to clickhoused

Thank you for your interest in contributing.

## Development setup

- A D compiler with frontend **2.097 or newer**: DMD 2.097+, LDC 1.27+ or GDC 12+.
- [dub](https://code.dlang.org).
- For integration tests that need a server: a ClickHouse server reachable on the native port, e.g.

  ```sh
  docker run -d --name clickhouse -p 9000:9000 -p 8123:8123 \
      -e CLICKHOUSE_SKIP_USER_SETUP=1 clickhouse/clickhouse-server
  ```

## Building and testing

```sh
dub build                           # library (thread mode, no dependencies)
dub test                            # unit tests, no server needed
dub run :integration-tests-phobos   # integration tests, thread mode
dub run :integration-tests-vibe     # integration tests, vibe.d fiber mode
```

Integration tests are written once in `integration-tests/` and run by both runners. To add one, write a `void function()` that throws on failure, and append it to `allTests` in `integration-tests/source/integrationtests/harness.d`.

## Code style and checks

CI runs these checks, so run them before sending a pull request:

```sh
dub run dscanner@0.15.2 -- --styleCheck .                   # static analysis
dub run dfmt@0.15.2 -- --inplace $(git ls-files '*.d')      # formatting
dub build -b docs                                           # documentation builds
```

- Formatting follows `dfmt`, configured in `.editorconfig`: Allman braces, 4-space indentation.
- **Document every public symbol with a Ddoc comment** (`///` or `/++ ... +/`). D-Scanner reports undocumented public declarations.
- **Add unit tests next to the code they test** (`unittest` blocks inside the module). A unittest preceded by `///` becomes a usage example in the generated docs; use that for short examples of public API. Undocumented unittests are fine for internal details.
- Prefer `@safe`. Keep `@trusted` blocks small, with a comment explaining why each one is safe.
- vibe.d-specific code belongs under `version (Have_vibe_core)`. The default build must not depend on vibe-core.

## Licensing of contributions

clickhoused is licensed under the [Boost Software License 1.0](LICENSE). By contributing, you agree that your contributions are licensed under the same terms.

**Do not copy or translate code from other ClickHouse clients**, such as clickhouse-c, clickhouse-cpp, clickhouse-go or the ClickHouse server, which are Apache-2.0, or the MIT/BSD-licensed clients. Reading them to understand the protocol is fine; the code you submit must be your own. Reproducing wire-format facts (packet layouts, constants, type encodings) is fine.

The CityHash v1.0.2 port is the only third-party code, and it keeps its original MIT notice.
