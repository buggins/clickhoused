/// Integration test runner for thread mode (blocking Phobos sockets).
module app;

import integrationtests.concurrency : testCancelFromThread;
import integrationtests.harness;

/// Tests that only make sense in thread mode.
immutable TestCase[] threadTests = [
    TestCase("thread: cancel from another thread", &testCancelFromThread, true),
];

int main()
{
    return runAllTests(RunnerContext("phobos", false), threadTests) == 0 ? 0 : 1;
}
