/++
A connection to a ClickHouse server over the native TCP protocol.

Example:
---
import clickhoused;

ConnectionOptions options;
options.host = "localhost";
auto conn = new Connection(options);
scope (exit) conn.close();

conn.exec("CREATE TABLE IF NOT EXISTS t (id UInt64) ENGINE = MergeTree ORDER BY id");
foreach (block; conn.query("SELECT number FROM system.numbers LIMIT 10"))
    writeln(block.column!UInt64Column("number").data);
---

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.connection;

import clickhoused.block : Block, readBlock, writeEmptyBlock;
import clickhoused.exception;
import clickhoused.io.backend : backendFor;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.io.transport : Transport;
import clickhoused.protocol.codes : Revision, ServerPacket;
import clickhoused.protocol.packets;
import clickhoused.settings : ConnectionOptions;

/// Statistics of a finished (or partially read) query.
struct QueryStats
{
    /// Accumulated progress counters.
    Progress progress;
    /// Profiling summary; filled in when the server sends it near the end of the query.
    ProfileInfo profileInfo;
}

/++
A connection to a ClickHouse server.

A connection runs one query at a time. Starting a query while the results of
the previous one are still being read throws a `ClientException`.

Errors:
$(UL
    $(LI `ServerException`: the query failed on the server; the connection stays usable,
        except after errors in query settings, which make the server close it.)
    $(LI `ConnectionException` / `ProtocolException`: the connection is closed and cannot be reused.)
    $(LI `ClientException` thrown while reading results, e.g. for an unsupported
        column type: the connection is closed, because the rest of the response cannot be skipped.)
)

The connection is not thread-safe. Call `close` when done; the garbage
collector does not close it.
+/
final class Connection
{
    private enum State
    {
        closed,
        ready,
        busy,
    }

    private ConnectionOptions options;
    private Transport transport;
    private BufferedReader reader;
    private BufferedWriter writer;
    private ServerInfo server;
    private ulong effectiveRevision;
    private State state = State.closed;
    private ClientIdentity identity;

    /// Called for every progress packet with the counters' increments.
    /// The accumulated totals are in `QueryResult.stats`.
    void delegate(const Progress increment) @safe onProgress;

    /++
    Called with every block of profile events (server performance counters).
    Columns: `host_name`, `current_time`, `thread_id`, `type`, `name`, `value`.
    The server sends them unless the setting `send_profile_events` is 0.
    +/
    void delegate(Block events) @safe onProfileEvents;

    /++
    Called with every block of server log entries. The server sends them only
    when the setting `send_logs_level` is set, e.g. to `"trace"`. Columns include
    `event_time`, `priority`, `source` and `text`.
    +/
    void delegate(Block entries) @safe onLog;

    /++
    Opens a connection and performs the handshake.

    Throws:
        `ConnectionException` if the server cannot be reached;
        `ServerException` if the server rejects the login;
        `ProtocolException` if the server does not speak the native protocol.
    +/
    this(ConnectionOptions options) @safe
    {
        import clickhoused : clickhousedVersionMajor, clickhousedVersionMinor, clickhousedVersionPatch;

        this.options = options;
        identity = ClientIdentity(options.clientName, clickhousedVersionMajor, clickhousedVersionMinor,
                clickhousedVersionPatch);
        connect();
    }

    /// Server name, version, timezone and revision, as received in the handshake.
    @property ref const(ServerInfo) serverInfo() const @safe pure nothrow return
    {
        return server;
    }

    /// Effective protocol revision: the smaller of the client's and the server's.
    @property ulong revision() const @safe pure nothrow
    {
        return effectiveRevision;
    }

    /// Whether the connection is open (it may be busy).
    @property bool isOpen() const @safe pure nothrow
    {
        return state != State.closed;
    }

    /// Whether a query is running, i.e. its results have not been fully read or closed.
    @property bool isBusy() const @safe pure nothrow
    {
        return state == State.busy;
    }

    /// Closes the connection. Calling it more than once is allowed.
    void close() @safe nothrow
    {
        if (transport !is null)
            transport.close();
        state = State.closed;
    }

    /++
    Checks that the server is alive.

    Throws: `ClientException` if the connection is closed or busy;
    `ConnectionException` or `ProtocolException` on failure (the connection is then closed).
    +/
    void ping() @safe
    {
        checkReady();
        guarded({
            writePing(writer);
            writer.flush();
            for (;;)
            {
                const packet = reader.readUVarInt();
                switch (packet)
                {
                case ServerPacket.pong:
                    return;
                case ServerPacket.progress: // may be left over from a previous query
                    readProgress(reader, effectiveRevision);
                    break;
                case ServerPacket.exception:
                    throw readException(reader);
                default:
                    throw unexpectedPacket(packet, "Pong");
                }
            }
        });
    }

    /++
    Starts a query and returns its results as a range of blocks.

    The connection stays busy until the result is fully read or closed.

    Params:
        sql = query text.
        settings = query settings, overriding `ConnectionOptions.settings`.
        parameters = values for `{name:Type}` placeholders in `sql`.
        queryId = query ID; by default the server generates one.

    Throws: `ClientException` if the connection is closed or busy;
    `ConnectionException` on network failure.
    Server errors are thrown as `ServerException` while reading the result.
    +/
    QueryResult query(string sql, const string[string] settings = null,
            const string[string] parameters = null, string queryId = null) @safe
    {
        checkReady();
        string[string] allSettings;
        allSettings["low_cardinality_allow_in_native_format"] = "0"; // LowCardinality is not supported yet
        foreach (name, value; options.settings)
            allSettings[name] = value;
        foreach (name, value; settings)
            allSettings[name] = value;

        guarded({
            writeQuery(writer, effectiveRevision, identity, queryId, sql, allSettings, parameters,
                options.quotaKey);
            writeDataHeader(writer);
            writeEmptyBlock(writer, effectiveRevision); // no external tables
            writer.flush();
        });
        state = State.busy;
        return new QueryResult(this);
    }

    /++
    Runs a query and discards its result data, e.g. for DDL statements.

    Params:
        sql = query text.
        settings = query settings, overriding `ConnectionOptions.settings`.
        parameters = values for `{name:Type}` placeholders in `sql`.

    Returns: statistics of the finished query.
    Throws: see `query`.
    +/
    QueryStats exec(string sql, const string[string] settings = null, const string[string] parameters = null) @safe
    {
        auto result = query(sql, settings, parameters);
        result.close();
        return result.stats;
    }

    private void connect() @safe
    {
        transport = options.transportFactory !is null
            ? options.transportFactory(options.host, options.port, options.connectTimeout) : backendFor(
                    options.ioMode).connect(options.host, options.port, options.connectTimeout);
        reader = new BufferedReader(transport);
        writer = new BufferedWriter(transport);
        state = State.ready;
        scope (failure)
            close(); // including a rejected login (ServerException)
        guarded({
            transport.setTimeouts(options.receiveTimeout, options.sendTimeout);
            writeHello(writer, identity, options.database, options.user, options.password);
            writer.flush();
            const packet = reader.readUVarInt();
            if (packet == ServerPacket.exception)
                throw readException(reader);
            if (packet != ServerPacket.hello)
                throw unexpectedPacket(packet, "Hello");
            server = readServerHello(reader);
            effectiveRevision = server.revision < Revision.client ? server.revision : Revision.client;
            writeAddendum(writer, effectiveRevision, options.quotaKey);
            writer.flush();
        });
    }

    private void checkReady() const @safe
    {
        if (state == State.closed)
            throw new ClientException("Connection is closed");
        if (state == State.busy)
            throw new ClientException("Connection is busy: read or close the previous query result first");
    }

    /// Runs `action`. Any error except a `ServerException` received between
    /// queries leaves the stream in an unknown state, so the connection is closed.
    private void guarded(scope void delegate() @safe action) @safe
    {
        try
            action();
        catch (ServerException e)
            throw e;
        catch (Exception e)
        {
            close();
            throw e;
        }
    }

    private static ProtocolException unexpectedPacket(ulong packet, string expected) @safe
    {
        import std.conv : to;

        return new ProtocolException("Unexpected packet " ~ packet.to!string ~ " from the server, expected "
                ~ expected);
    }
}

/++
Results of a running query: an input range of `Block`s with data.

Blocks are read from the network lazily, as the range is iterated. Empty
blocks are skipped. The column names and types are available from `header`
after the first call to `empty`.

The connection is busy until the range is exhausted or `close` is called.
If the server reports an error, `empty` or `popFront` throws a `ServerException`.
+/
final class QueryResult
{
    private Connection conn;
    private Block current;
    private bool finished;

    /// Column names and types, without rows. Null until the server sends them
    /// (some statements, e.g. DDL, have no result columns at all).
    Block header;
    /// Totals block (`WITH TOTALS`), if the server sent one.
    Block totals;
    /// Extremes block (`extremes = 1`), if the server sent one.
    Block extremes;
    /// Query statistics so far.
    QueryStats stats;

    private this(Connection conn) @safe
    {
        this.conn = conn;
    }

    /// Whether all blocks have been consumed. Reads from the network if needed.
    @property bool empty() @safe
    {
        if (current is null && !finished)
            fetch();
        return current is null;
    }

    /// The current block.
    @property Block front() @safe
    {
        assert(!empty, "QueryResult.front called on an empty range");
        return current;
    }

    /// Moves to the next block.
    void popFront() @safe
    {
        assert(!empty, "QueryResult.popFront called on an empty range");
        current = null;
    }

    /// Whether the server has finished sending the result.
    @property bool isFinished() const @safe pure nothrow
    {
        return finished;
    }

    /++
    Reads and discards the rest of the result, freeing the connection.

    Throws: `ServerException` if the server reports an error in the remaining part.
    +/
    void close() @safe
    {
        while (!finished)
        {
            current = null;
            fetch();
        }
        current = null;
    }

    /// Reads packets until a non-empty data block or the end of the result.
    private void fetch() @safe
    {
        auto r = conn.reader;
        const revision = conn.effectiveRevision;
        const timezone = conn.server.timezone;
        bool gotBlock;
        conn.guarded({
            while (!gotBlock && !finished)
            {
                const packet = r.readUVarInt();
                switch (packet)
                {
                case ServerPacket.data:
                    r.readString(); // table name
                    auto block = readBlock(r, revision, timezone);
                    if (header is null)
                        header = block;
                    if (block.rows > 0)
                    {
                        current = block;
                        gotBlock = true;
                    }
                    break;
                case ServerPacket.totals:
                    r.readString();
                    totals = readBlock(r, revision, timezone);
                    break;
                case ServerPacket.extremes:
                    r.readString();
                    extremes = readBlock(r, revision, timezone);
                    break;
                case ServerPacket.progress:
                    const increment = readProgress(r, revision);
                    stats.progress.add(increment);
                    if (conn.onProgress !is null)
                        conn.onProgress(increment);
                    break;
                case ServerPacket.profileInfo:
                    stats.profileInfo = readProfileInfo(r);
                    break;
                case ServerPacket.profileEvents:
                    r.readString();
                    auto events = readBlock(r, revision, timezone);
                    if (conn.onProfileEvents !is null)
                        conn.onProfileEvents(events);
                    break;
                case ServerPacket.log:
                    r.readString();
                    auto entries = readBlock(r, revision, timezone);
                    if (conn.onLog !is null)
                        conn.onLog(entries);
                    break;
                case ServerPacket.tableColumns:
                    r.readString(); // table name
                    r.readString(); // columns description
                    break;
                case ServerPacket.exception:
                    auto e = readException(r);
                    finish();
                    throw e;
                case ServerPacket.endOfStream:
                    finish();
                    break;
                default:
                    throw Connection.unexpectedPacket(packet, "query result");
                }
            }
        });
    }

    private void finish() @safe nothrow
    {
        finished = true;
        if (conn.state == Connection.State.busy)
            conn.state = Connection.State.ready;
    }
}

version (unittest)
{
    import clickhoused.io.mock : MockTransport;
    import clickhoused.types.numeric : UInt8Column;

    /// Builds server packets for scripted-server tests.
    private final class ServerScript
    {
        MockTransport transport;
        BufferedWriter w;

        this() @safe
        {
            transport = new MockTransport;
            w = new BufferedWriter(transport);
        }

        void hello() @safe
        {
            w.writeUVarInt(ServerPacket.hello);
            w.writeString("ClickHouse");
            w.writeUVarInt(26);
            w.writeUVarInt(11);
            w.writeUVarInt(54_492);
            w.writeString("UTC");
            w.writeString("test");
            w.writeUVarInt(1);
        }

        void dataBlock(ubyte[] values) @safe
        {
            import clickhoused.block : writeBlock;

            auto block = new Block;
            auto c = new UInt8Column("x", "UInt8");
            c.data = values;
            block.columns = [c];
            block.rows = values.length;
            w.writeUVarInt(ServerPacket.data);
            w.writeString("");
            writeBlock(w, block, Revision.client);
        }

        void progress(ulong rows) @safe
        {
            w.writeUVarInt(ServerPacket.progress);
            foreach (v; [rows, rows * 8, 0, 0, 0, 1000])
                w.writeUVarInt(v);
        }

        void exception(int code, string message) @safe
        {
            w.writeUVarInt(ServerPacket.exception);
            w.writeFixed(code);
            w.writeString("DB::Exception");
            w.writeString(message);
            w.writeString("");
            w.writeFixed(false);
        }

        void endOfStream() @safe
        {
            w.writeUVarInt(ServerPacket.endOfStream);
        }

        Connection connect() @safe
        {
            w.flush();
            transport.feed(transport.written);
            transport.clearWritten();
            ConnectionOptions options;
            options.transportFactory = (host, port, timeout) => cast(Transport) transport;
            return new Connection(options);
        }

        /// Queues more server output on an already connected script.
        void send() @safe
        {
            const before = transport.written.length;
            w.flush();
            auto data = transport.written[before .. $].dup;
            transport.written = transport.written[0 .. before];
            transport.feed(data);
        }
    }
}

@safe unittest
{
    // Handshake, then a query returning header + two data blocks
    auto s = new ServerScript;
    s.hello();
    auto conn = s.connect();
    assert(conn.serverInfo.versionMajor == 26 && conn.revision == Revision.client);

    s.dataBlock([]); // header
    s.progress(3);
    s.dataBlock([1, 2]);
    s.dataBlock([3]);
    s.endOfStream();
    s.send();

    ubyte[] values;
    auto result = conn.query("SELECT x");
    assert(conn.isBusy);
    foreach (block; result)
        values ~= block.column!UInt8Column("x").data;
    assert(values == [1, 2, 3]);
    assert(result.header.columns[0].name == "x");
    assert(result.stats.progress.readRows == 3);
    assert(!conn.isBusy && conn.isOpen);
}

@safe unittest
{
    import std.exception : assertThrown, collectException;

    // Server errors keep the connection usable; misuse while busy is rejected
    auto s = new ServerScript;
    s.hello();
    auto conn = s.connect();

    s.exception(60, "Unknown table");
    s.send();
    const e = collectException!ServerException(conn.exec("SELECT * FROM missing"));
    assert(e !is null && e.code == 60);
    assert(conn.isOpen && !conn.isBusy);

    s.dataBlock([7]);
    s.endOfStream();
    s.send();
    auto result = conn.query("SELECT 7");
    assertThrown!ClientException(conn.query("SELECT 8")); // busy
    result.close();
    assert(!conn.isBusy);
}

@safe unittest
{
    import std.exception : assertThrown;

    // A stream cut in the middle of a block closes the connection
    auto s = new ServerScript;
    s.hello();
    auto conn = s.connect();
    s.w.writeUVarInt(ServerPacket.data);
    s.w.writeString("");
    s.w.writeUVarInt(0); // end of block info
    s.w.writeUVarInt(1); // 1 column
    s.w.writeUVarInt(5); // 5 rows, but no column follows
    s.send();
    auto result = conn.query("SELECT x");
    assertThrown!ConnectionException(result.empty);
    assert(!conn.isOpen);
    assertThrown!ClientException(conn.query("SELECT 1"));
}

@safe unittest
{
    import std.exception : assertThrown;

    // Login failure
    auto s = new ServerScript;
    s.exception(516, "Authentication failed");
    assertThrown!ServerException(s.connect());
}
