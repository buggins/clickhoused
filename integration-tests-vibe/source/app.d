/// Integration test runner for fiber mode: every test runs inside a vibe.d task.
module app;

import vibe.core.core : exitEventLoop, runEventLoop, runTask;

import clickhoused : clickhousedHasVibe;
import integrationtests.harness;

static assert(clickhousedHasVibe, "clickhoused must be built with vibe-core support for this runner");

int main()
{
    int failures;
    runTask(() nothrow {
        scope (exit)
            exitEventLoop();
        try
            failures = runAllTests(RunnerContext("vibe", true));
        catch (Exception e)
            failures = 1;
    });
    runEventLoop();
    return failures == 0 ? 0 : 1;
}
