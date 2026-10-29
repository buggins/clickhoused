/// Fiber-mode tests that need vibe-core: concurrency on one event loop,
/// cancellation from another task, task interruption.
module vibetests;

import core.time : Duration, msecs, seconds;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.exception : enforce;

import vibe.core.core : runTask, sleep;
import vibe.core.task : Task;

import clickhoused;
import integrationtests.harness : TestCase;
import integrationtests.server : connectToServer, serverOptions;

/// Tests registered by the vibe.d runner.
immutable TestCase[] vibeTests = [
    TestCase("fiber: queries run concurrently", &testConcurrentQueries, true),
    TestCase("fiber: cancel from another task", &testCancelFromTask, true),
    TestCase("fiber: interrupted task closes connection", &testInterrupt, true),
    TestCase("fiber: pool shared by tasks", &testPoolTasks, true),
];

/// Tasks on one thread share a pool; never more connections than the limit.
void testPoolTasks()
{
    PoolOptions p;
    p.maxConnections = 3;
    auto pool = new ConnectionPool(serverOptions(), p);
    scope (exit)
        pool.close();
    size_t inUse, maxInUse, failures, done;
    Task[] tasks;
    foreach (t; 0 .. 20)
        tasks ~= runTask(() nothrow{
            foreach (i; 0 .. 10)
            {
                try
                {
                    auto c = pool.lockConnection();
                    if (++inUse > maxInUse)
                        maxInUse = inUse;
                    c.exec("SELECT sleep(0.01)");
                    inUse--;
                    done++;
                }
                catch (Exception)
                    failures++;
            }
        });
    foreach (t; tasks)
        t.join();
    enforce(failures == 0 && done == 200, "failed queries");
    enforce(maxInUse <= 3, "more connections than the limit");
    enforce(maxInUse >= 2, "the tasks did not overlap");
}

/// Ten one-second queries in ten tasks on one thread take about one second, not ten:
/// waiting for the server does not block the event loop.
void testConcurrentQueries()
{
    enum tasks = 10;
    size_t done, failures;
    auto sw = StopWatch(AutoStart.yes);
    Task[] running;
    foreach (i; 0 .. tasks)
        running ~= runTask(() nothrow{
            try
            {
                auto conn = connectToServer();
                scope (exit)
                    conn.close();
                conn.exec("SELECT sleep(1)");
                done++;
            }
            catch (Exception)
                failures++;
        });
    foreach (t; running)
        t.join();
    enforce(failures == 0 && done == tasks, "some queries failed");
    enforce(sw.peek < 5.seconds, "queries did not overlap: took " ~ sw.peek.toString);
}

/// Another task on the same thread cancels a running query.
void testCancelFromTask()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto result = conn.query("SELECT number FROM system.numbers"); // endless
    auto canceller = runTask(() nothrow{
        try
        {
            sleep(300.msecs);
            conn.cancel();
        }
        catch (Exception)
        {
        }
    });
    ulong rows;
    foreach (block; result)
        rows += block.rows;
    canceller.join();
    enforce(rows > 0 && result.isFinished && conn.isOpen && !conn.isBusy, "state after cancel");
    conn.ping();
}

/// `Task.interrupt` while waiting for the server propagates `InterruptException`
/// and closes the connection.
void testInterrupt()
{
    import vibe.core.task : InterruptException;

    Connection conn;
    Exception caught;
    auto worker = runTask(() nothrow{
        try
        {
            conn = connectToServer();
            conn.exec("SELECT sleep(3)");
        }
        catch (Exception e)
            caught = e;
    });
    sleep(500.msecs);
    worker.interrupt();
    worker.join();
    enforce(cast(InterruptException) caught !is null, "expected InterruptException, got "
            ~ (caught is null ? "nothing" : typeid(caught).name));
    enforce(conn !is null && !conn.isOpen, "the connection should be closed");
}

/// Outside a task, automatic selection uses thread mode even with vibe-core compiled in.
void checkThreadModeOutsideTasks()
{
    auto conn = new Connection(serverOptions());
    scope (exit)
        conn.close();
    enforce(conn.ioBackend == "phobos", "outside tasks the backend is " ~ conn.ioBackend);
}
