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
import clickhoused.insert : Inserter;
import clickhoused.literal : quoteIdentifier;
import clickhoused.mapping : RowRange;
import clickhoused.io.backend : IoBackend, IoLock, backendFor;
import clickhoused.io.buffer : BufferedReader, BufferedWriter, readString, readUVarInt, writeString, writeUVarInt;
import clickhoused.io.tls : TlsContext, TlsTransport;
import clickhoused.io.transport : Transport;
import clickhoused.protocol.codes : ClientPacket, Revision, ServerPacket;
import clickhoused.protocol.packets;
import clickhoused.settings : ConnectionOptions, HostPort;
import dbwire.client.hosts : connectFirst, orderHosts;
import dbwire.client.pool : Poolable;

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
final class Connection : Poolable
{
    package enum State
    {
        closed,
        ready,
        busy,
    }

    package ConnectionOptions options;
    package IoBackend backend;
    private HostPort connectedHost;
    package Transport transport;
    /// An `Inserter` is sending data; `cancel` must not write then.
    package bool insertActive;
    // What cancel() may do now: changed and read under cancelLock, so that a cancel from
    // another thread never gets into one of the client's packets, and never reaches the
    // server after the next query has started.
    private enum QueryPhase
    {
        none, // no query: cancel does nothing
        writing, // the client is writing a query (or a packet during its result): a cancel waits
        reading, // the client is reading a result: a cancel is written at once
    }

    private QueryPhase queryPhase;
    private bool cancelPending; // cancel() was called while writing
    private IoLock cancelLock;
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
    Opens a connection and performs the handshake. With several hosts in
    `options.hosts`, connects to the first that answers.

    Throws:
        `ConnectionException` if no server can be reached (the message lists each attempt);
        `ServerException` if the server rejects the login;
        `ProtocolException` if the server does not speak the native protocol.
    +/
    this(ConnectionOptions options) @safe
    {
        import clickhoused : clickhousedVersionMajor, clickhousedVersionMinor, clickhousedVersionPatch;

        this.options = options;
        // The user and host name go with every query: looked up once
        identity = ClientIdentity(options.clientName, clickhousedVersionMajor, clickhousedVersionMinor,
                clickhousedVersionPatch, localOsUser(), localHostName());
        connect();
    }

    /++
    Opens a connection described by a connection string, e.g.
    `clickhouse://user:password@host:9000/database?compress=lz4`.
    See `ConnectionOptions.fromDsn`.

    Throws: `ClientException` for a malformed string; otherwise as the other constructor.
    +/
    this(string dsn) @safe
    {
        this(ConnectionOptions.fromDsn(dsn));
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

    /// The server this connection is connected to (one of `ConnectionOptions.hosts`), with the port in use.
    @property HostPort host() const @safe pure nothrow
    {
        return connectedHost;
    }

    /// The negotiated TLS protocol, e.g. `"TLSv1.3"`; empty for a connection without TLS.
    @property string tlsVersion() @safe
    {
        auto tls = cast(TlsTransport) transport;
        return tls is null ? "" : tls.protocolVersion;
    }

    /// Name of the I/O backend in use: `"phobos"` (thread mode) or `"vibe"` (fiber mode).
    @property string ioBackend() const @safe pure nothrow
    {
        return backend.name;
    }

    /++
    Asks the server to stop the running query. The result then ends early:
    reading it further returns the blocks already in flight, then finishes.

    This is the one method that may be called from another thread (thread mode)
    or another task on the same thread (fiber mode) while a query runs. A cancel
    made while the query is still being sent goes out right after it. It does
    nothing if no query is running.

    Throws: `ClientException` during an INSERT (use `Inserter.abort`);
    `ConnectionException` if the request cannot be sent.
    +/
    void cancel() @safe
    {
        cancelLock.lock();
        scope (exit)
            cancelLock.unlock();
        final switch (queryPhase)
        {
        case QueryPhase.reading:
            writeCancel();
            break;
        case QueryPhase.writing:
            cancelPending = true; // sent by endWriting
            break;
        case QueryPhase.none:
            if (insertActive)
                throw new ClientException("Cannot cancel an INSERT: use Inserter.abort");
            break;
        }
    }

    // The Cancel packet is the single byte 0x03. It goes straight to the transport, bypassing
    // the buffered writer, which is idle then. Called with cancelLock held.
    private void writeCancel() @safe
    {
        static immutable ubyte[1] packet = [cast(ubyte) ClientPacket.cancel];
        transport.write(packet[]);
    }

    /// Starts writing a query, or a packet while its result is read: a cancel waits until `endWriting`.
    package void beginWriting() @safe
    {
        cancelLock.lock();
        scope (exit)
            cancelLock.unlock();
        queryPhase = QueryPhase.writing;
    }

    /// The writing is over and the result is read: sends a cancel requested meanwhile.
    package void endWriting() @safe
    {
        cancelLock.lock();
        scope (exit)
            cancelLock.unlock();
        if (cancelPending)
            writeCancel();
        cancelPending = false;
        queryPhase = QueryPhase.reading;
    }

    /// The query is over: nothing left to cancel.
    package void endQuery() @safe nothrow
    {
        void reset() @safe nothrow
        {
            queryPhase = QueryPhase.none;
            cancelPending = false;
        }

        if (cancelLock is null)
            return reset();
        try
        {
            cancelLock.lock();
            scope (exit)
                cancelLock.unlock();
            reset();
        }
        catch (Exception)
            reset(); // the lock failed (the backends' locks don't throw); nothing can be cancelled anyway
    }

    /// Closes the connection. Calling it more than once is allowed.
    void close() @safe nothrow
    {
        endQuery();
        insertActive = false;
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
        state = State.busy; // before any I/O: another task must not start a query meanwhile
        scope (exit)
            if (state == State.busy)
                state = State.ready; // also after a server error; guarded closes on others
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
        state = State.busy; // before any I/O: writing may let another task run (fiber mode)
        guarded({
            beginWriting();
            writeQuery(writer, effectiveRevision, identity, queryId, sql, compressionEnabled, allSettings,
                parameters, options.quotaKey);
            writeEndOfData(); // no external tables
            endWriting();
        });
        return new QueryResult(this);
    }

    /++
    Starts an INSERT whose data is sent from the client.

    The query can also transform the data on the server with the `input()`
    table function; it must then end with `FORMAT Native` (the server rejects
    it otherwise), and the rows sent have the structure given to `input()`:
    ---
    auto ins = conn.beginInsert("INSERT INTO t SELECT x * 2, upper(s) FROM input('x UInt32, s String') FORMAT Native");
    ins.addRow(21, "abc"); // stored as (42, 'ABC')
    ins.finish();
    ---

    Params:
        insertQuery = an INSERT without data, e.g. `INSERT INTO t (a, b) VALUES`,
            or an `INSERT ... SELECT ... FROM input(...) FORMAT Native`.
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
        state = State.busy; // before any I/O: writing may let another task run (fiber mode)
        insertActive = true;
        guarded({
            writeQuery(writer, effectiveRevision, identity, null, insertQuery, compressionEnabled, allSettings,
                null, options.quotaKey);
            writeEndOfData(); // no external tables
        });
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
    Runs a query and returns its rows as structs of type `T` (see
    `clickhoused.mapping`). Columns are matched to fields by name; extra
    columns are ignored.

    Returns: an input range of `T`; the connection is busy until it is
    exhausted or closed.
    +/
    RowRange!T query(T)(string sql, const string[string] settings = null, const string[string] parameters = null)
            if (is(T == struct))
    {
        return RowRange!T(query(sql, settings, parameters));
    }

    /++
    Runs a query and returns its first row as a `T`; the rest of the result is discarded.

    Throws: `ClientException` if the query returns no rows.
    +/
    T queryRow(T)(string sql, const string[string] settings = null, const string[string] parameters = null)
            if (is(T == struct))
    {
        auto rows = query!T(sql, settings, parameters);
        scope (exit)
            rows.close();
        if (rows.empty)
            throw new ClientException("The query returned no rows");
        return rows.front;
    }

    /++
    Runs a query and returns the value in the first column of the first row,
    e.g. `queryValue!ulong("SELECT count() FROM t")`. `T` is any type a struct
    field may have (see `clickhoused.mapping`); the rest of the result is discarded.

    Throws: `ClientException` if the query returns no rows or the value does not convert to `T`.
    +/
    T queryValue(T)(string sql, const string[string] settings = null, const string[string] parameters = null)
    {
        import clickhoused.mapping : readValue;

        auto result = query(sql, settings, parameters);
        scope (exit)
            result.close();
        if (result.empty)
            throw new ClientException("The query returned no rows");
        return readValue!T(result.front.columns[0], 0);
    }

    /++
    Inserts structs (or any input range of structs) into `table`, one column
    per mapped field (see `clickhoused.mapping`).

    If a value does not fit its column, the insert is abandoned and the
    connection closed; rows from blocks already sent may have been stored.

    Returns: statistics of the insert.
    +/
    QueryStats insert(R)(string table, R rows, const string[string] settings = null) if (!is(R : Block))
    {
        import clickhoused.mapping : columnNames;
        import std.range : ElementType;

        alias T = ElementType!R;
        static assert(is(T == struct), "insert expects a range of structs, not of " ~ T.stringof);
        string columns;
        foreach (i, name; columnNames!T)
            columns ~= (i ? ", " : "") ~ quoteIdentifier(name);
        auto ins = beginInsert("INSERT INTO " ~ table ~ " (" ~ columns ~ ") VALUES", settings);
        scope (failure)
            ins.abort();
        foreach (ref row; rows)
            ins.addStruct(row);
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
        result.drain();
        return result.stats;
    }

    /// Connection settings merged with per-query `settings`.
    package string[string] mergedSettings(const string[string] settings) const @safe
    {
        import std.conv : to;

        string[string] all;
        if (options.compression == Compression.lz4)
            all["network_compression_method"] = "LZ4";
        else if (options.compression == Compression.zstd)
        {
            all["network_compression_method"] = "ZSTD";
            all["network_zstd_compression_level"] = options.zstdLevel.to!string;
        }
        if (options.simpleNativeFormats && serverVersionAtLeast(24, 10))
            all["output_format_native_write_json_as_string"] = "1"; // JSON as text
        if (options.simpleNativeFormats && serverVersionAtLeast(25, 6))
            all["output_format_native_use_flattened_dynamic_and_json_serialization"] = "1"; // Dynamic without binary values
        foreach (name, value; options.settings)
            all[name] = value;
        foreach (name, value; settings)
            all[name] = value;
        return all;
    }

    /// Whether the server version is `major.minor` or newer.
    private bool serverVersionAtLeast(ulong major, ulong minor) const @safe pure nothrow
    {
        return server.versionMajor > major || (server.versionMajor == major && server.versionMinor >= minor);
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
        backend = backendFor(options.ioMode);
        cancelLock = backend.newLock();
        // Loads OpenSSL and the certificates once; problems here are not host-specific
        auto tlsContext = options.secure ? TlsContext.client(options.tls) : null;

        // Try the hosts in turn. Network and protocol failures move on to the next
        // host; a login rejected by the server does not.
        void tryHost(HostPort endpoint) @safe
        {
            connectTo(endpoint, tlsContext);
        }

        connectFirst(candidateHosts(), &tryHost, "ClickHouse");
    }

    private HostPort[] candidateHosts() const @safe
    {
        auto hosts = options.hosts.length ? options.hosts.dup : [
            HostPort(options.host, options.port)
        ];
        foreach (ref h; hosts)
            h.port = options.effectivePort(h.port);
        return orderHosts(hosts, options.hostSelection);
    }

    private void connectTo(HostPort endpoint, TlsContext tlsContext) @safe
    {
        auto raw = options.transportFactory !is null
            ? options.transportFactory(endpoint.host, endpoint.port, options.connectTimeout) : backend.connect(
                    endpoint.host, endpoint.port, options.connectTimeout);
        // The TLS handshake closes the raw transport if it fails
        transport = tlsContext is null ? raw : new TlsTransport(raw, backend, tlsContext, endpoint.host,
                options.tls, options.connectTimeout);
        connectedHost = endpoint;
        reader = new BufferedReader(transport);
        writer = new BufferedWriter(transport);
        compressedInput = null;
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
        if (empty) // reads the next block if needed: not in an assert, which -release removes
            throw new ClientException("QueryResult.front called on an empty range");
        return current;
    }

    /// Moves to the next block.
    void popFront() @safe
    {
        if (empty)
            throw new ClientException("QueryResult.popFront called on an empty range");
        current = null;
    }

    /// Whether the server has finished sending the result.
    @property bool isFinished() const @safe pure nothrow
    {
        return finished;
    }

    /++
    Stops reading: cancels the query if it is still running, discards what the
    server already sent, and frees the connection. Server errors in the
    discarded part are ignored. Does nothing if the result is finished.
    +/
    void close() @safe
    {
        current = null;
        if (finished)
            return;
        conn.cancel(); // does nothing on a connection closed by an error; fetch then finishes
        while (!finished)
        {
            current = null;
            try
                fetch();
            catch (ServerException)
            {
                // the query is over; errors after a cancel do not matter
            }
        }
        current = null;
    }

    /++
    Reads and discards the rest of the result without cancelling the query,
    waiting until the server has finished it (as `Connection.exec` does).

    Throws: `ServerException` if the server reports an error.
    +/
    void drain() @safe
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
        if (!conn.isOpen)
        {
            finished = true; // closed after an error: the rest of the result is gone
            return;
        }
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
                    conn.beginWriting(); // no cancel may get into the middle of this packet
                    conn.writeEndOfData();
                    conn.endWriting();
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
        if (gotBlock && conn.options.yieldBetweenBlocks)
            conn.backend.yieldNow();
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
        conn.endQuery();
        finished = true;
        if (conn.state == Connection.State.busy)
            conn.state = Connection.State.ready;
    }
}

version (unittest)
{
    import clickhoused.protocol.testserver : ScriptedServer;
    import clickhoused.types.numeric : UInt8Column;

    /// A transport that runs a hook once in the middle of a write or a read, as a yield
    /// in fiber mode lets another task run there.
    private final class ReentrantTransport : Transport
    {
        import core.time : Duration;
        import clickhoused.io.mock : MockTransport;

        MockTransport inner;
        void delegate() @safe onWrite, onRead;

        this(MockTransport inner) @safe
        {
            this.inner = inner;
        }

        private static void fire(ref void delegate() @safe hook) @safe
        {
            if (hook is null)
                return;
            auto h = hook;
            hook = null;
            h();
        }

        size_t read(scope ubyte[] buffer) @safe
        {
            fire(onRead);
            return inner.read(buffer);
        }

        void write(scope const(ubyte)[] data) @safe
        {
            fire(onWrite);
            inner.write(data);
        }

        bool dataAvailable() @safe
        {
            return inner.dataAvailable();
        }

        void close() @safe nothrow
        {
            inner.close();
        }

        bool connected() const @safe nothrow
        {
            return inner.connected();
        }

        void setTimeouts(Duration receive, Duration send) @safe
        {
            inner.setTimeouts(receive, send);
        }
    }
}

@safe unittest
{
    import std.exception : assertThrown;

    // The connection is busy from the first byte a query or ping writes until it is over
    auto s = new ScriptedServer;
    s.hello();
    s.send();
    auto t = new ReentrantTransport(s.transport);
    ConnectionOptions options;
    options.transportFactory = (host, port, timeout) => cast(Transport) t;
    auto conn = new Connection(options);

    t.onWrite = () { assertThrown!ClientException(conn.query("SELECT 2")); };
    s.dataBlock([1]);
    s.endOfStream();
    s.send();
    auto result = conn.query("SELECT 1");
    assert(t.onWrite is null); // the hook ran
    result.drain();

    s.w.writeUVarInt(ServerPacket.pong);
    s.send();
    t.onRead = () { assertThrown!ClientException(conn.query("SELECT 2")); };
    conn.ping();
    assert(t.onRead is null && !conn.isBusy);

    // A cancel made while the query is being written goes out right after it, not inside it
    s.dataBlock([1]);
    s.endOfStream();
    s.send();
    s.transport.clearWritten();
    t.onWrite = () { conn.cancel(); };
    result = conn.query("SELECT 1");
    assert(t.onWrite is null && s.transport.written[$ - 1] == ClientPacket.cancel);
    auto sent = s.clientOutput();
    assert(sent.readUVarInt() == ClientPacket.query); // the query packet is intact
    result.drain();
}

@safe unittest
{
    import std.exception : assertThrown;

    // cancel() writes only while a result is being read
    auto s = new ScriptedServer;
    s.hello();
    auto conn = s.connect();
    conn.cancel(); // idle: nothing to cancel
    assert(s.transport.written.length == 0);

    s.dataBlock([1]);
    s.endOfStream();
    s.send();
    auto result = conn.query("SELECT 1");
    s.transport.clearWritten();
    conn.cancel();
    assert(s.transport.written == [cast(ubyte) ClientPacket.cancel]);
    result.drain();
    s.transport.clearWritten();
    conn.cancel(); // the result is over: a late cancel is not sent
    assert(s.transport.written.length == 0);

    s.tableColumns();
    s.dataBlock([]); // the INSERT's header
    s.send();
    auto ins = conn.beginInsert("INSERT INTO t VALUES");
    assertThrown!ClientException(conn.cancel());
    ins.abort();
    conn.cancel(); // the insert is over (and the connection closed): nothing to refuse
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
    // The flattened Dynamic form is requested from 25.6 on, JSON as text from 24.10 on, unless switched off or
    // set explicitly
    enum flattened = "output_format_native_use_flattened_dynamic_and_json_serialization";
    enum jsonText = "output_format_native_write_json_as_string";
    auto s = new ScriptedServer;
    s.hello(); // 26.11
    auto conn = s.connect();
    assert(conn.mergedSettings(null)[flattened] == "1");
    assert(conn.mergedSettings([flattened: "0"])[flattened] == "0");
    conn.server.versionMajor = 25;
    conn.server.versionMinor = 5;
    assert(flattened !in conn.mergedSettings(null) && conn.mergedSettings(null)[jsonText] == "1");
    conn.server.versionMajor = 24;
    conn.server.versionMinor = 9;
    assert(jsonText !in conn.mergedSettings(null));
    conn.server.versionMajor = 25;
    conn.server.versionMinor = 6;
    conn.options.simpleNativeFormats = false;
    assert(flattened !in conn.mergedSettings(null) && jsonText !in conn.mergedSettings(null));
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
    result.close(); // cleanup code still works after the error
    result.drain();
    conn.cancel(); // nothing to cancel on a closed connection
    assert(result.empty);
    assertThrown!ClientException(result.front); // not an assert: also checked with -release
}

@safe unittest
{
    import std.exception : assertThrown;

    // Login failure
    auto s = new ScriptedServer;
    s.exception(516, "Authentication failed");
    assertThrown!ServerException(s.connect());
}
