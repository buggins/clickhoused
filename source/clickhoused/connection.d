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
import clickhoused.compress.frame : CompressedInput, CompressedOutput, Compression, zstdAvailable;
import clickhoused.exception;
import clickhoused.insert : Inserter, quoteIdentifier;
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
    package enum State
    {
        closed,
        ready,
        busy,
    }

    package ConnectionOptions options;
    package Transport transport;
    package BufferedReader reader;
    package BufferedWriter writer;
    /// Readers and writers for the data part of Data packets: the same as
    /// `reader` and `writer`, or decompressing/compressing streams over them.
    package BufferedReader blockReader;
    /// ditto
    package BufferedWriter blockWriter;
    private CompressedInput compressedInput;
    package ServerInfo server;
    package ulong effectiveRevision;
    package State state = State.closed;
    package ClientIdentity identity;

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
        const allSettings = mergedSettings(settings);
        guarded({
            writeQuery(writer, effectiveRevision, identity, queryId, sql, compressionEnabled, allSettings,
                parameters, options.quotaKey);
            writeEndOfData(); // no external tables
        });
        state = State.busy;
        return new QueryResult(this);
    }

    /++
    Starts an INSERT whose data is sent from the client.

    Params:
        insertQuery = an INSERT without data, e.g. `INSERT INTO t (a, b) VALUES`.
        settings = query settings, overriding `ConnectionOptions.settings`.

    Returns: an `Inserter` for sending the rows. The connection is busy until
        `Inserter.finish` or `Inserter.abort` is called.
    Throws: `ServerException` if the server rejects the query (e.g. an unknown table);
        `ClientException` if the connection is closed or busy.
    +/
    Inserter beginInsert(string insertQuery, const string[string] settings = null) @safe
    {
        checkReady();
        const allSettings = mergedSettings(settings);
        guarded({
            writeQuery(writer, effectiveRevision, identity, null, insertQuery, compressionEnabled, allSettings,
                null, options.quotaKey);
            writeEndOfData(); // no external tables
        });
        state = State.busy;
        return new Inserter(this);
    }

    /++
    Inserts the rows of `block` into `table`, matching columns by name.

    Params:
        table = table name, inserted into the SQL as is (quote it if needed, e.g. with `quoteIdentifier`).
        block = rows to insert; its columns must have the table's types.
        settings = query settings, overriding `ConnectionOptions.settings`.

    Returns: statistics of the insert.
    Throws: `ClientException` if the block does not match the table (nothing is inserted);
        `ServerException` if the insert fails on the server.
    +/
    QueryStats insert(string table, Block block, const string[string] settings = null) @safe
    {
        string columns;
        foreach (i, c; block.columns)
            columns ~= (i ? ", " : "") ~ quoteIdentifier(c.name);
        auto ins = beginInsert("INSERT INTO " ~ table ~ " (" ~ columns ~ ") VALUES", settings);
        try
            ins.send(block);
        catch (ClientException e)
        {
            if (!ins.isFinished && isOpen)
                ins.finish(); // ends the insert with no rows
            throw e;
        }
        return ins.finish();
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

    /// Connection settings merged with per-query `settings`.
    package string[string] mergedSettings(const string[string] settings) const @safe
    {
        import std.conv : to;

        string[string] all;
        all["low_cardinality_allow_in_native_format"] = "0"; // LowCardinality is not supported yet
        if (options.compression == Compression.lz4)
            all["network_compression_method"] = "LZ4";
        else if (options.compression == Compression.zstd)
        {
            all["network_compression_method"] = "ZSTD";
            all["network_zstd_compression_level"] = options.zstdLevel.to!string;
        }
        foreach (name, value; options.settings)
            all[name] = value;
        foreach (name, value; settings)
            all[name] = value;
        return all;
    }

    /// Whether data blocks are compressed on this connection.
    package @property bool compressionEnabled() const @safe pure nothrow
    {
        return options.compression != Compression.none;
    }

    /// Writes an empty Data packet: the end-of-data marker.
    package void writeEndOfData() @safe
    {
        writeDataHeader(writer);
        writeEmptyBlock(blockWriter, effectiveRevision);
        flushBlock();
    }

    /// Sends a block written to `blockWriter`, ending the compressed frame if any.
    package void flushBlock() @safe
    {
        if (blockWriter !is writer)
            blockWriter.flush();
        writer.flush();
    }

    /// Reads the rest of a Data, Totals or Extremes packet: table name and block.
    package Block readDataBlock() @safe
    {
        reader.readString(); // table name, never compressed
        auto block = readBlock(blockReader, effectiveRevision, server.timezone);
        if (compressedInput !is null && (blockReader.buffered != 0 || !compressedInput.atFrameBoundary))
            throw new ProtocolException("A compressed block does not end at a frame boundary");
        return block;
    }

    /++
    Reads the body of an informational packet (progress, profile info, profile
    events, log) and dispatches it to `stats` and the callbacks.

    Returns: false if `packet` is not an informational packet; nothing is read then.
    +/
    package bool readInfoPacket(ulong packet, ref QueryStats stats) @safe
    {
        switch (packet)
        {
        case ServerPacket.progress:
            const increment = readProgress(reader, effectiveRevision);
            stats.progress.add(increment);
            if (onProgress !is null)
                onProgress(increment);
            return true;
        case ServerPacket.profileInfo:
            stats.profileInfo = readProfileInfo(reader);
            return true;
        case ServerPacket.profileEvents:
            reader.readString();
            auto events = readBlock(reader, effectiveRevision, server.timezone);
            if (onProfileEvents !is null)
                onProfileEvents(events);
            return true;
        case ServerPacket.log:
            reader.readString();
            auto entries = readBlock(reader, effectiveRevision, server.timezone);
            if (onLog !is null)
                onLog(entries);
            return true;
        default:
            return false;
        }
    }

    private void connect() @safe
    {
        if (options.compression == Compression.zstd && !zstdAvailable)
            throw new ClientException("ZSTD compression is not compiled in: build clickhoused with the 'zstd' "
                    ~ "configuration, or use Compression.lz4");
        transport = options.transportFactory !is null
            ? options.transportFactory(options.host, options.port, options.connectTimeout) : backendFor(
                    options.ioMode).connect(options.host, options.port, options.connectTimeout);
        reader = new BufferedReader(transport);
        writer = new BufferedWriter(transport);
        if (compressionEnabled)
        {
            compressedInput = new CompressedInput(reader);
            blockReader = new BufferedReader(compressedInput);
            // The block writer's buffer size is the maximum frame size
            blockWriter = new BufferedWriter(new CompressedOutput(writer, options.compression, options.zstdLevel),
                    1024 * 1024);
        }
        else
        {
            blockReader = reader;
            blockWriter = writer;
        }
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

    package void checkReady() const @safe
    {
        if (state == State.closed)
            throw new ClientException("Connection is closed");
        if (state == State.busy)
            throw new ClientException("Connection is busy: read or close the previous query result first");
    }

    /// Runs `action`. Any error except a `ServerException` received between
    /// queries leaves the stream in an unknown state, so the connection is closed.
    package void guarded(scope void delegate() @safe action) @safe
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

    package static ProtocolException unexpectedPacket(ulong packet, string expected) @safe
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
    private bool insertWithoutData;

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
        bool gotBlock;
        conn.guarded({
            while (!gotBlock && !finished)
            {
                const packet = r.readUVarInt();
                switch (packet)
                {
                case ServerPacket.data:
                    auto block = conn.readDataBlock();
                    if (header is null)
                        header = block;
                    if (block.rows > 0)
                    {
                        current = block;
                        gotBlock = true;
                    }
                    break;
                case ServerPacket.totals:
                    totals = conn.readDataBlock();
                    break;
                case ServerPacket.extremes:
                    extremes = conn.readDataBlock();
                    break;
                case ServerPacket.tableColumns:
                    // The server is waiting for INSERT data, which a plain query
                    // cannot supply: end the insert with no rows and report it.
                    r.readString(); // table name
                    r.readString(); // columns description
                    conn.writeEndOfData();
                    insertWithoutData = true;
                    break;
                case ServerPacket.exception:
                    auto e = readException(r);
                    finish();
                    throw e;
                case ServerPacket.endOfStream:
                    finish();
                    break;
                default:
                    if (!conn.readInfoPacket(packet, stats))
                        throw Connection.unexpectedPacket(packet, "query result");
                }
            }
        });
        // Outside `guarded`: the stream is intact and the connection stays usable
        if (finished && insertWithoutData)
        {
            insertWithoutData = false;
            throw new ClientException("The query expects INSERT data, which query() and exec() cannot send: "
                    ~ "use Connection.beginInsert or Connection.insert, or put the VALUES in the query text");
        }
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
    import clickhoused.protocol.testserver : ScriptedServer;
    import clickhoused.types.numeric : UInt8Column;
}

@safe unittest
{
    // Handshake, then a query returning header + two data blocks
    auto s = new ScriptedServer;
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
    auto s = new ScriptedServer;
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
    auto s = new ScriptedServer;
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
    auto s = new ScriptedServer;
    s.exception(516, "Authentication failed");
    assertThrown!ServerException(s.connect());
}
