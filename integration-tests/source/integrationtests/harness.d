/++
Integration test harness shared by the thread (Phobos) and fiber (vibe.d)
runners. Tests are written once here; each runner calls `runAllTests` in its
own I/O context.

Tests marked `needsServer` run only when the `CLICKHOUSE_HOST` environment
variable is set (see `integrationtests.server`); otherwise they are skipped.
+/
module integrationtests.harness;

import core.exception : AssertError;
import std.stdio : writefln, stderr;

import integrationtests.basic;
import integrationtests.compression;
import integrationtests.concurrency;
import integrationtests.insert;
import integrationtests.mapping;
import integrationtests.pool;
import integrationtests.server : serverConfigured;
import integrationtests.smoke;
import integrationtests.types;

/// Integration test entry point. Throws on failure.
alias TestFunction = void function();

/// A named integration test.
struct TestCase
{
    /// Test name used in reports.
    string name;
    /// Test body.
    TestFunction run;
    /// Whether the test needs a ClickHouse server.
    bool needsServer;
}

/// All integration tests, in execution order.
immutable TestCase[] allTests = [
    TestCase("library metadata", &testLibraryMetadata),
    TestCase("handshake and ping", &testHandshakeAndPing, true),
    TestCase("SELECT 1", &testSelectOne, true),
    TestCase("many blocks", &testManyBlocks, true),
    TestCase("basic types", &testBasicTypes, true),
    TestCase("DDL and INSERT ... SELECT", &testDdlAndInsertSelect, true),
    TestCase("server error keeps connection", &testServerError, true),
    TestCase("unsupported type closes connection", &testUnsupportedType, true),
    TestCase("busy connection", &testBusyConnection, true),
    TestCase("LowCardinality arrives as plain type", &testLowCardinality, true),
    TestCase("settings and parameters", &testSettingsAndParameters, true),
    TestCase("date and time types", &testDateTimeTypes, true),
    TestCase("UUID", &testUUID, true),
    TestCase("Enum8 and Enum16", &testEnums, true),
    TestCase("Nullable", &testNullable, true),
    TestCase("cell getters", &testCellGetters, true),
    TestCase("callbacks", &testCallbacks, true),
    TestCase("insert all types", &testInsertAllTypes, true),
    TestCase("insert a block", &testInsertBlock, true),
    TestCase("large streaming insert", &testLargeInsert, true),
    TestCase("insert with defaults", &testInsertDefaults, true),
    TestCase("insert errors", &testInsertErrors, true),
    TestCase("network compression", &testCompression, true),
    TestCase("automatic I/O backend", &testIoBackendSelection, true),
    TestCase("close() cancels the query", &testCloseCancelsQuery, true),
    TestCase("connection string", &testDsnConnect, true),
    TestCase("host failover", &testFailover, true),
    TestCase("pool: reuse", &testPoolReuse, true),
    TestCase("pool: limit and wait", &testPoolLimit, true),
    TestCase("pool: discard closed and busy", &testPoolDiscards, true),
    TestCase("pool: idle expiry", &testPoolExpiry, true),
    TestCase("struct mapping round trip", &testStructRoundTrip, true),
    TestCase("struct mapping errors", &testStructErrors, true),
    TestCase("SQL literals", &testFormatLiteral, true),
];

/// Settings passed from the runner to the tests.
struct RunnerContext
{
    /// Runner name used in reports, e.g. "phobos" or "vibe".
    string name;
    /// Whether the runner expects vibe-core support to be compiled in.
    bool expectVibe;
}

/// The context of the runner currently executing tests.
RunnerContext currentRunner;

/++
Runs all integration tests, plus `extraTests` from the runner, and prints a report.

Returns: the number of failed tests.
+/
int runAllTests(RunnerContext runner, const TestCase[] extraTests = null)
{
    currentRunner = runner;
    const withServer = serverConfigured();
    if (!withServer)
        writefln("[%s] CLICKHOUSE_HOST is not set: skipping tests that need a server", runner.name);
    int failures, skipped;
    foreach (test; allTests ~ extraTests)
    {
        if (test.needsServer && !withServer)
        {
            skipped++;
            writefln("[%s] SKIP  %s", runner.name, test.name);
            continue;
        }
        // Tests may fail with `enforce` (Exception) or `assert` (AssertError).
        try
        {
            test.run();
            writefln("[%s] PASS  %s", runner.name, test.name);
        }
        catch (AssertError e)
        {
            failures++;
            stderr.writefln("[%s] FAIL  %s: %s (%s:%s)", runner.name, test.name, e.msg, e.file, e.line);
        }
        catch (Exception e)
        {
            failures++;
            stderr.writefln("[%s] FAIL  %s: %s", runner.name, test.name, e.msg);
        }
    }
    writefln("[%s] %d test(s), %d failed, %d skipped", runner.name, allTests.length + extraTests.length, failures,
            skipped);
    return failures;
}
