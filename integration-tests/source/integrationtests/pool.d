/// Connection string, failover and connection pool tests.
module integrationtests.pool;

import core.time : msecs, seconds;
import std.algorithm.searching : canFind;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.exception : assertThrown, collectException, enforce;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : serverOptions;

/// A DSN for the test server, with `extra` appended to the query string.
string serverDsn(string extra = null)
{
    import std.uri : encodeComponent;

    const o = serverOptions();
    auto dsn = "clickhouse://" ~ encodeComponent(o.user) ~ ":" ~ encodeComponent(
            o.password) ~ "@"
        ~ HostPort(o.host, o.port).toString() ~ "/default?compress=" ~ o.compression.to!string;
    return extra.length ? dsn ~ "&" ~ extra : dsn;
}

/// Connecting with a connection string; unknown parameters become settings.
void testDsnConnect()
{
    auto conn = new Connection(serverDsn("max_threads=3"));
    scope (exit)
        conn.close();
    auto block = conn.firstBlock("SELECT toUInt64(getSetting('max_threads')) AS v");
    enforce(block.column!UInt64Column("v").data == [3], "setting from the DSN not applied");
    enforce(conn.host.port == serverOptions().port, "connected host");
}

/// The first host refuses the connection; the second one is used.
void testFailover()
{
    auto options = serverOptions();
    const reachable = HostPort(options.host, options.port);
    options.hosts = [HostPort("127.0.0.1", 1), reachable];
    options.connectTimeout = 2.seconds;
    auto conn = new Connection(options);
    scope (exit)
        conn.close();
    enforce(conn.host == reachable, "connected to " ~ conn.host.toString());
    conn.ping();

    options.hosts = [HostPort("127.0.0.1", 1), HostPort("127.0.0.1", 2)];
    auto e = collectException!ConnectionException(new Connection(options));
    enforce(e !is null && e.msg.canFind("127.0.0.1:1") && e.msg.canFind("127.0.0.1:2"),
            "the error should list every host: " ~ (e is null ? "" : e.msg));
}

private ConnectionPool newPool(size_t max, int waitMsecs = 30_000, int idleMsecs = 300_000)
{
    PoolOptions p;
    p.maxConnections = max;
    p.waitTimeout = waitMsecs.msecs;
    p.maxIdleTime = idleMsecs.msecs;
    return new ConnectionPool(serverOptions(), p);
}

/// A returned connection is reused.
void testPoolReuse()
{
    auto pool = newPool(2);
    scope (exit)
        pool.close();
    Connection first;
    {
        auto c = pool.lockConnection();
        c.ping();
        first = c.connection;
        enforce(pool.activeConnections == 1 && pool.idleConnections == 0, "counts while in use");
    }
    enforce(pool.activeConnections == 0 && pool.idleConnections == 1, "counts after release");
    auto c = pool.lockConnection();
    enforce(c.connection is first, "the idle connection was not reused");
    enforce(c.firstBlock("SELECT 1 AS x").column!UInt8Column("x").data == [1]);
}

/// At the limit, lockConnection waits, then times out; a release unblocks it.
void testPoolLimit()
{
    auto pool = newPool(2, 300);
    scope (exit)
        pool.close();
    auto a = pool.lockConnection();
    auto b = pool.lockConnection();
    auto sw = StopWatch(AutoStart.yes);
    assertThrown!ClientException(pool.lockConnection());
    enforce(sw.peek >= 250.msecs && sw.peek < 5.seconds, "wait time " ~ sw.peek.toString);
    a.release();
    auto c = pool.lockConnection();
    c.ping();
    b.ping();
}

/// Closed or busy connections are not returned to the pool.
void testPoolDiscards()
{
    auto pool = newPool(2);
    scope (exit)
        pool.close();
    {
        auto c = pool.lockConnection();
        c.close();
    }
    enforce(pool.idleConnections == 0 && pool.activeConnections == 0, "closed connection kept");
    Connection busy;
    {
        auto c = pool.lockConnection();
        c.query("SELECT number FROM system.numbers LIMIT 100000"); // result left unread
        busy = c.connection;
    }
    enforce(pool.idleConnections == 0 && !busy.isOpen, "busy connection kept");
    auto c = pool.lockConnection();
    c.ping();
}

/// Idle connections past their idle time are replaced.
void testPoolExpiry()
{
    import core.thread : Thread;

    auto pool = newPool(2, 30_000, 100);
    scope (exit)
        pool.close();
    // The temporary handle returns the connection to the pool at the end of the statement
    Connection old = pool.lockConnection().connection;
    enforce(pool.idleConnections == 1, "connection not returned");
    Thread.sleep(250.msecs);
    auto c = pool.lockConnection();
    enforce(c.connection !is old && !old.isOpen, "expired connection was reused");
    c.ping();
}

/// Thread mode: threads share one pool; never more connections than the limit.
void testPoolThreads()
{
    import core.atomic : atomicFetchAdd, atomicFetchSub, atomicLoad, atomicOp;
    import core.thread : Thread;

    auto pool = newPool(3);
    scope (exit)
        pool.close();
    shared int inUse, maxInUse, failures, done;
    Thread[] threads;
    foreach (t; 0 .. 8)
    {
        threads ~= new Thread({
            foreach (i; 0 .. 20)
            {
                try
                {
                    auto c = pool.lockConnection();
                    const now = atomicFetchAdd(inUse, 1) + 1;
                    for (int m = atomicLoad(maxInUse); now > m; m = atomicLoad(maxInUse))
                    {
                        import core.atomic : cas;

                        if (cas(&maxInUse, m, now))
                            break;
                    }
                    c.exec("SELECT sleep(0.01)");
                    atomicFetchSub(inUse, 1);
                    atomicOp!"+="(done, 1);
                }
                catch (Exception)
                    atomicOp!"+="(failures, 1);
            }
        });
        threads[$ - 1].start();
    }
    foreach (t; threads)
        t.join();
    enforce(atomicLoad(failures) == 0 && atomicLoad(done) == 160, "failed queries: " ~ atomicLoad(failures).to!string);
    enforce(atomicLoad(maxInUse) <= 3, "more connections than the limit: " ~ atomicLoad(maxInUse).to!string);
}
