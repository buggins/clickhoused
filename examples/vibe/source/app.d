/++
clickhoused in a vibe.d application: tasks share a connection pool, and
waiting for ClickHouse suspends only the waiting task, not the thread.

Run with `dub run :example-vibe`. The server address comes from the
`CLICKHOUSE_DSN` environment variable (default `clickhouse://localhost`).
+/
module app;

import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.process : environment;
import std.stdio : writefln;

import vibe.core.core : exitEventLoop, runEventLoop, runTask;
import vibe.core.task : Task;

import clickhoused;

void main()
{
    // Inside vibe.d tasks the pool's connections use vibe-core sockets automatically
    auto pool = new ConnectionPool(environment.get("CLICKHOUSE_DSN", "clickhouse://localhost") ~ "?pool_max=4");

    // Runs one query on a pooled connection
    void query(int n) nothrow
    {
        try
        {
            auto conn = pool.lockConnection();
            const value = conn.queryValue!ulong("SELECT sleep(0.5) + {n:UInt8}", null, [
                "n": n.to!string
            ]);
            print("task %s: got %s via %s", n, value, conn.ioBackend);
        }
        catch (Exception e)
            print("task %s failed: %s", n, e.msg);
    }

    void work() nothrow
    {
        scope (exit)
            exitEventLoop();
        try
        {
            auto sw = StopWatch(AutoStart.yes);
            Task[] tasks;
            foreach (i; 0 .. 8)
                tasks ~= runTask(&query, i);
            foreach (t; tasks)
                t.join();
            // 8 half-second queries on 4 pooled connections: about one second in total
            print("8 queries in %s", sw.peek);
            pool.close();
        }
        catch (Exception e)
            print("error: %s", e.msg);
    }

    runTask(&work);
    runEventLoop();
}

/// `writefln` that never throws, for use in tasks.
void print(Args...)(string format, Args args) nothrow
{
    try
        writefln(format, args);
    catch (Exception)
    {
    }
}
