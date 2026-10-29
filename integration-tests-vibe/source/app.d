/// Integration test runner for fiber mode: every test runs inside a vibe.d task.
module app;

import vibe.core.core : exitEventLoop, runEventLoop, runTask;

import clickhoused : clickhousedHasVibe;
import integrationtests.harness;
import integrationtests.server : serverConfigured;
import vibetests;

static assert(clickhousedHasVibe, "clickhoused must be built with vibe-core support for this runner");

int main()
{
    int failures;
    if (serverConfigured())
        checkThreadModeOutsideTasks();

    void runTests() nothrow
    {
        scope (exit)
            exitEventLoop();
        try
            failures = runAllTests(RunnerContext("vibe", true), vibeTests);
        catch (Exception e)
            failures = 1;
    }

    runTask(&runTests);
    runEventLoop();
    return failures == 0 ? 0 : 1;
}
