/++
Integration test harness shared by the thread (Phobos) and fiber (vibe.d)
runners. Tests are written once here; each runner calls `runAllTests` in its
own I/O context.
+/
module integrationtests.harness;

import core.exception : AssertError;
import std.stdio : writefln, stderr;

import integrationtests.smoke;

/// Integration test entry point. Throws on failure.
alias TestFunction = void function();

/// A named integration test.
struct TestCase
{
    /// Test name used in reports.
    string name;
    /// Test body.
    TestFunction run;
}

/// All integration tests, in execution order.
immutable TestCase[] allTests = [
    TestCase("library metadata", &testLibraryMetadata),
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
Runs all integration tests and prints a report.

Returns: the number of failed tests.
+/
int runAllTests(RunnerContext runner)
{
    currentRunner = runner;
    int failures;
    foreach (test; allTests)
    {
        // Tests may fail with `enforce` (Exception) or `assert` (AssertError).
        try
        {
            test.run();
            writefln("[%s] PASS  %s", runner.name, test.name);
        }
        catch (AssertError e)
        {
            failures++;
            stderr.writefln("[%s] FAIL  %s: %s", runner.name, test.name, e.msg);
        }
        catch (Exception e)
        {
            failures++;
            stderr.writefln("[%s] FAIL  %s: %s", runner.name, test.name, e.msg);
        }
    }
    writefln("[%s] %d test(s), %d failed", runner.name, allTests.length, failures);
    return failures;
}
