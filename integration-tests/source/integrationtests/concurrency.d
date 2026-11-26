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
    enforce(result.cancelled, "the cut result isn't marked cancelled");
    enforce(conn.firstBlock("SELECT 42 AS x").column!UInt8Column("x").data == [42], "query after cancel");
}

/++
`QueryResult.cancelled` (#94): false for a result read to its end, also when
the cancel came after the server had finished the query (it ignores such a
cancel), and when `close()` comes after the end.
+/
void testCancelledFlag()
{
    import core.thread : Thread;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    ulong rows;
    auto result = conn.query("SELECT number FROM numbers(10)");
    foreach (block; result)
        rows += block.rows;
    enforce(rows == 10 && !result.cancelled, "a finished result is marked cancelled");

    // The server is most likely done after the pause, and then ignores the cancel; on a slow server
    // the cancel may still stop the query. Either way the flag must match the end the server sent
    // (the summary comes only after a finished query); at least one attempt must be a late cancel.
    bool late, lateClose;
    foreach (attempt; 0 .. 5)
    {
        result = conn.query("SELECT number FROM numbers(10)");
        Thread.sleep(300.msecs); // the server finishes the query meanwhile
        conn.cancel(); // too late: the server ignores it
        rows = 0;
        foreach (block; result)
            rows += block.rows;
        const finished = result.stats.profileInfo.rows == 10;
        enforce(result.cancelled != finished, "a late cancel: the flag doesn't match the server's end");
        enforce(!finished || rows == 10, "a late cancel lost rows");
        late = late || finished;

        result = conn.query("SELECT number FROM numbers(10)");
        enforce(!result.empty, "no rows");
        Thread.sleep(300.msecs);
        result.close();
        enforce(result.cancelled != (result.stats.profileInfo.rows == 10),
                "close() after the end: the flag doesn't match the server's end");
        lateClose = lateClose || !result.cancelled;
        if (late && lateClose)
            break;
    }
    enforce(late && lateClose, "every late cancel stopped the query");
    enforce(!conn.exec("SELECT 1").cancelled && conn.isOpen && !conn.isBusy, "state after a late cancel");
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
    enforce(result.cancelled, "the cut result isn't marked cancelled");
    conn.ping();

    // exec reports the cancel in its statistics
    canceller = new Thread({ Thread.sleep(300.msecs); conn.cancel(); });
    canceller.start();
    sw.reset();
    const stats = conn.exec("SELECT number FROM system.numbers WHERE sleepEachRow(0.001) = 0",
            ["max_block_size": "100"]);
    canceller.join();
    enforce(sw.peek < 10.seconds && stats.cancelled, "exec of a cancelled query: not marked cancelled");
    conn.ping();
}
