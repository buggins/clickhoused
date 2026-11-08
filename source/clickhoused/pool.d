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

import clickhoused.connection : Connection;
import clickhoused.settings : ConnectionOptions;
import dbwire.client.pool : PoolCore, PoolLease, Poolable;

/// Pool limits and connection reuse rules; from `dbwire.client.pool` (package dbwire), re-exported here.
public import dbwire.client.pool : PoolOptions;

/++
A pool of connections to one server (or one set of failover hosts).

`lockConnection` hands out a `PooledConnection`, which returns the connection
when it goes out of scope. Connections that are closed, broken, or still busy
with an unread result when returned are not reused.

The pool logic is `dbwire.client.pool.PoolCore`; this class opens
`Connection`s for it.
+/
final class ConnectionPool
{
    private PoolCore core;

    /++
    Creates an empty pool; connections are opened on demand.

    Params:
        connectionOptions = options for every connection of the pool.
        poolOptions = pool limits.

    Throws: `ClientException` if `poolOptions.maxConnections` is 0.
    +/
    this(ConnectionOptions connectionOptions, PoolOptions poolOptions = PoolOptions.init) @safe
    {
        Poolable open() @safe
        {
            return new Connection(connectionOptions);
        }

        core = new PoolCore(poolOptions, connectionOptions.ioMode, &open);
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
        return PooledConnection(core.acquire());
    }

    /// Number of idle connections available to the caller (its thread's set in fiber mode).
    @property size_t idleConnections() @safe
    {
        return core.idleConnections;
    }

    /// Number of connections handed out to the caller's context and not yet returned.
    @property size_t activeConnections() @safe
    {
        return core.activeConnections;
    }

    /++
    Closes all idle connections and stops handing out new ones. Connections in
    use are closed when they are returned. In fiber mode, the idle connections
    of other threads are closed by those threads when they next use the pool.
    +/
    void close() @safe
    {
        core.close();
    }
}

/++
A connection taken from a `ConnectionPool`. It behaves like the `Connection`
itself and returns it to the pool when it goes out of scope (or on `release`).
It cannot be copied.
+/
struct PooledConnection
{
    private PoolLease lease;
    private Connection conn;

    @disable this(this);

    private this(PoolLease lease) @safe
    {
        import std.algorithm.mutation : move;

        conn = cast(Connection) lease.connection(); // a checked cast: the pool's factory only creates Connections
        this.lease = move(lease);
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
        conn = null;
        lease.release();
    }
}
