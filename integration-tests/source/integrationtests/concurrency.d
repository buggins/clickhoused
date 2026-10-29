/// Cancellation and I/O backend tests. Thread-only tests are registered by the
/// Phobos runner; fiber-only tests live in the vibe.d runner.
module integrationtests.concurrency;

import core.time : msecs, seconds;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.exception : enforce;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.harness : currentRunner;
import integrationtests.server : connectToServer;

/// Automatic backend selection: fiber mode inside vibe.d tasks, thread mode otherwise.
void testIoBackendSelection()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    const expected = currentRunner.expectVibe ? "vibe" : "phobos";
    enforce(conn.ioBackend == expected, "backend is " ~ conn.ioBackend ~ ", expected " ~ expected);
}

/// Closing an unfinished result cancels the query instead of reading it all.
void testCloseCancelsQuery()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto sw = StopWatch(AutoStart.yes);
    auto result = conn.query("SELECT number FROM system.numbers"); // endless
    size_t blocks;
    foreach (block; result)
        if (++blocks == 3)
            break;
    result.close();
    enforce(sw.peek < 10.seconds, "close() did not cancel the query");
    enforce(result.isFinished && !conn.isBusy && conn.isOpen, "connection state after close");
    enforce(conn.firstBlock("SELECT 42 AS x").column!UInt8Column("x").data == [42], "query after cancel");
}

/// Thread mode: `Connection.cancel` from another thread stops a running query.
void testCancelFromThread()
{
    import core.thread : Thread;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto result = conn.query("SELECT number FROM system.numbers"); // endless
    auto canceller = new Thread({ Thread.sleep(300.msecs); conn.cancel(); });
    canceller.start();
    auto sw = StopWatch(AutoStart.yes);
    ulong rows;
    foreach (block; result)
        rows += block.rows;
    canceller.join();
    enforce(sw.peek < 10.seconds, "cancel did not stop the query");
    enforce(rows > 0 && result.isFinished && conn.isOpen && !conn.isBusy, "state after cancel");
    conn.ping();
}
