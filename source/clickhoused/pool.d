/++
Connection pool for thread mode and fiber mode.

Example:
---
auto pool = new ConnectionPool("clickhouse://localhost/default?pool_max=8");

// In any thread, or in any vibe.d task:
{
    auto conn = pool.lockConnection();       // waits if all 8 are in use
    conn.exec("INSERT INTO log VALUES (now(), 'x')");
}                                            // returned to the pool here
---

In thread mode all threads share one set of connections. In fiber mode each
thread has its own set, because a vibe.d connection cannot move between event
loops; the limits apply per thread. Which mode a call uses follows
`ConnectionOptions.ioMode`, as for single connections.

Idle connections are checked lazily, when connections are taken or returned,
so the pool needs no background thread or timer.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.pool;

import core.thread : Thread;
import core.time : Duration, MonoTime, hours, minutes, seconds;

import clickhoused.connection : Connection;
import clickhoused.exception : ClientException;
import clickhoused.io.backend : PoolSync, backendFor;
import clickhoused.settings : ConnectionOptions;

/// Pool limits and connection reuse rules.
struct PoolOptions
{
    /// Maximum number of open connections (per thread in fiber mode).
    size_t maxConnections = 16;
    /// How long `lockConnection` waits for a free connection before failing.
    Duration waitTimeout = 30.seconds;
    /// Idle connections older than this are closed.
    Duration maxIdleTime = 5.minutes;
    /// Connections older than this are closed when returned; `Duration.zero` means no limit.
    Duration maxLifetime = 1.hours;
    /// A connection idle for longer than this is pinged before being handed out.
    Duration pingAfterIdle = 30.seconds;

    /++
    Reads pool options from the `pool_*` parameters of a connection string:
    `pool_max`, and `pool_wait_timeout`, `pool_max_idle_time`,
    `pool_max_lifetime`, `pool_ping_after_idle` in seconds.

    Throws: `ClientException` if a value is invalid.
    +/
    static PoolOptions fromDsn(string dsn) @safe
    {
        import core.time : dur;
        import std.algorithm.searching : findSplit;
        import std.array : split;
        import std.conv : ConvException, to;

        PoolOptions options;
        auto q = dsn.findSplit("?");
        foreach (pair; q[2].split("&"))
        {
            auto kv = pair.findSplit("=");
            const key = kv[0];
            const value = kv[2];
            Duration secondsValue()
            {
                double v;
                try
                    v = value.to!double;
                catch (ConvException)
                    throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "'");
                if (!(v >= 0))
                    throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "'");
                return dur!"hnsecs"(cast(long)(v * 10_000_000));
            }

            switch (key)
            {
            case "pool_max":
                try
                    options.maxConnections = value.to!size_t;
                catch (ConvException)
                    throw new ClientException("Invalid value '" ~ value ~ "' for 'pool_max'");
                if (options.maxConnections == 0)
                    throw new ClientException("'pool_max' must be at least 1");
                break;
            case "pool_wait_timeout":
                options.waitTimeout = secondsValue();
                break;
            case "pool_max_idle_time":
                options.maxIdleTime = secondsValue();
                break;
            case "pool_max_lifetime":
                options.maxLifetime = secondsValue();
                break;
            case "pool_ping_after_idle":
                options.pingAfterIdle = secondsValue();
                break;
            default:
                break;
            }
        }
        return options;
    }

    ///
    @safe unittest
    {
        const o = PoolOptions.fromDsn("clickhouse://h/db?pool_max=4&pool_wait_timeout=2.5&max_threads=1");
        assert(o.maxConnections == 4 && o.waitTimeout == 2500.msecs);
    }
}

/++
A pool of connections to one server (or one set of failover hosts).

`lockConnection` hands out a `PooledConnection`, which returns the connection
when it goes out of scope. Connections that are closed, broken, or still busy
with an unread result when returned are not reused.
+/
final class ConnectionPool
{
    private ConnectionOptions connectionOptions;
    private PoolOptions poolOptions;
    private SubPool threadPool;
    private SubPool[Thread] fiberPools;
    private PoolSync fiberPoolsLock;
    private bool closed;

    /++
    Creates an empty pool; connections are opened on demand.

    Params:
        connectionOptions = options for every connection of the pool.
        poolOptions = pool limits.
    +/
    this(ConnectionOptions connectionOptions, PoolOptions poolOptions = PoolOptions.init) @safe
    {
        import clickhoused.io.phobos : ThreadPoolSync;

        if (poolOptions.maxConnections == 0)
            throw new ClientException("PoolOptions.maxConnections must be at least 1");
        this.connectionOptions = connectionOptions;
        this.poolOptions = poolOptions;
        threadPool = new SubPool(this, new ThreadPoolSync);
        fiberPoolsLock = new ThreadPoolSync;
    }

    /// Creates a pool from a connection string, including its `pool_*` parameters.
    this(string dsn) @safe
    {
        this(ConnectionOptions.fromDsn(dsn), PoolOptions.fromDsn(dsn));
    }

    /++
    Takes a connection from the pool, opening a new one if none is idle and
    the limit allows it; otherwise waits up to `PoolOptions.waitTimeout`.

    Throws: `ClientException` if the pool is closed or no connection became
    free in time; connection errors when a new connection cannot be opened.
    +/
    PooledConnection lockConnection() @safe
    {
        auto pool = currentSubPool();
        return PooledConnection(pool, pool.acquire());
    }

    /// Number of idle connections available to the caller (its thread's set in fiber mode).
    @property size_t idleConnections() @safe
    {
        auto pool = currentSubPool();
        pool.sync.lock();
        scope (exit)
            pool.sync.unlock();
        return pool.idle.length;
    }

    /// Number of connections handed out to the caller's context and not yet returned.
    @property size_t activeConnections() @safe
    {
        auto pool = currentSubPool();
        pool.sync.lock();
        scope (exit)
            pool.sync.unlock();
        return pool.active;
    }

    /++
    Closes all idle connections and stops handing out new ones. Connections in
    use are closed when they are returned. In fiber mode, the idle connections
    of other threads are closed by those threads when they next use the pool.
    +/
    void close() @safe
    {
        closed = true;
        threadPool.closeIdle();
        fiberPoolsLock.lock();
        SubPool own;
        if (auto p = currentThread() in fiberPools)
            own = *p;
        fiberPoolsLock.unlock();
        if (own !is null)
            own.closeIdle();
    }

    private SubPool currentSubPool() @safe
    {
        auto backend = backendFor(connectionOptions.ioMode);
        if (backend.name != "vibe")
            return threadPool;
        auto self = currentThread();
        fiberPoolsLock.lock();
        scope (exit)
            fiberPoolsLock.unlock();
        if (auto p = self in fiberPools)
            return *p;
        auto pool = new SubPool(this, backend.newPoolSync());
        fiberPools[self] = pool;
        return pool;
    }
}

/++
A connection taken from a `ConnectionPool`. It behaves like the `Connection`
itself and returns it to the pool when it goes out of scope (or on `release`).
It cannot be copied.
+/
struct PooledConnection
{
    private SubPool pool;
    private Connection conn;

    @disable this(this);

    private this(SubPool pool, Connection conn) @safe
    {
        this.pool = pool;
        this.conn = conn;
    }

    ~this() @safe
    {
        release();
    }

    /// The pooled connection. Null after `release`.
    @property Connection connection() @safe pure nothrow
    {
        return conn;
    }

    ///
    alias connection this;

    /// Returns the connection to the pool now. Calling it again does nothing.
    void release() @safe
    {
        if (pool !is null && conn !is null)
            pool.release(conn);
        pool = null;
        conn = null;
    }
}

/// The connections of one context: all threads (thread mode) or one thread (fiber mode).
private final class SubPool
{
    struct Idle
    {
        Connection conn;
        MonoTime since;
    }

    ConnectionPool owner;
    PoolSync sync;
    Idle[] idle; // most recently returned last
    size_t active;
    MonoTime[Connection] openedAt;

    this(ConnectionPool owner, PoolSync sync) @safe
    {
        this.owner = owner;
        this.sync = sync;
    }

    Connection acquire() @safe
    {
        const options = owner.poolOptions;
        const deadline = MonoTime.currTime + options.waitTimeout;
        for (;;)
        {
            Connection[] expired;
            Connection candidate;
            Duration idleFor;
            bool create;

            sync.lock();
            {
                scope (exit)
                    sync.unlock();
                for (;;)
                {
                    if (owner.closed)
                        throw new ClientException("The connection pool is closed");
                    takeExpired(expired);
                    if (idle.length)
                    {
                        candidate = idle[$ - 1].conn;
                        idleFor = MonoTime.currTime - idle[$ - 1].since;
                        idle = idle[0 .. $ - 1];
                        active++;
                        break;
                    }
                    if (active < options.maxConnections)
                    {
                        active++;
                        create = true;
                        break;
                    }
                    const remaining = deadline - MonoTime.currTime;
                    if (remaining <= Duration.zero || !sync.wait(remaining))
                        throw new ClientException("Timed out waiting for a free connection in the pool");
                }
            }
            foreach (c; expired)
                c.close();

            if (create)
            {
                try
                {
                    auto conn = new Connection(owner.connectionOptions);
                    sync.lock();
                    openedAt[conn] = MonoTime.currTime;
                    sync.unlock();
                    return conn;
                }
                catch (Exception e)
                {
                    forget(null);
                    throw e;
                }
            }

            if (idleFor < options.pingAfterIdle)
                return candidate;
            try
            {
                candidate.ping();
                return candidate;
            }
            catch (Exception)
            {
                candidate.close(); // dead: try another one
                forget(candidate);
            }
        }
    }

    void release(Connection conn) @safe
    {
        const lifetime = owner.poolOptions.maxLifetime;
        sync.lock();
        const opened = openedAt.get(conn, MonoTime.currTime);
        const tooOld = lifetime != Duration.zero && MonoTime.currTime - opened > lifetime;
        const reuse = !owner.closed && conn.isOpen && !conn.isBusy && !tooOld;
        if (reuse)
            idle ~= Idle(conn, MonoTime.currTime);
        else
            openedAt.remove(conn);
        active--;
        sync.notifyAll();
        sync.unlock();
        if (!reuse)
            conn.close(); // a busy connection has an unread result: it cannot be reused
    }

    /// Closes all idle connections.
    void closeIdle() @safe
    {
        sync.lock();
        auto toClose = idle;
        idle = null;
        foreach (entry; toClose)
            openedAt.remove(entry.conn);
        sync.notifyAll();
        sync.unlock();
        foreach (entry; toClose)
            entry.conn.close();
    }

    /// Removes a connection that will not come back, freeing its slot. Call without the lock.
    private void forget(Connection conn) @safe
    {
        sync.lock();
        if (conn !is null)
            openedAt.remove(conn);
        active--;
        sync.notifyAll();
        sync.unlock();
    }

    /// Moves idle connections past their idle time or lifetime to `expired`. Call with the lock held.
    private void takeExpired(ref Connection[] expired) @safe
    {
        const now = MonoTime.currTime;
        const options = owner.poolOptions;
        size_t kept;
        foreach (entry; idle)
        {
            const opened = openedAt.get(entry.conn, now);
            if (now - entry.since > options.maxIdleTime
                    || (options.maxLifetime != Duration.zero && now - opened > options.maxLifetime)
                    || !entry.conn.isOpen)
            {
                expired ~= entry.conn;
                openedAt.remove(entry.conn);
            }
            else
                idle[kept++] = entry;
        }
        idle = idle[0 .. kept];
    }
}

private Thread currentThread() @trusted nothrow
{
    return Thread.getThis(); // the current thread object; no unsafe memory access
}

version (unittest)
{
    import core.time : msecs;
}
