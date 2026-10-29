/++
Inserting data: streaming INSERTs in the native format.

An INSERT over the native protocol works like this: the client sends the
query (`INSERT INTO t (a, b) VALUES`, without data); the server replies with a
header block giving the column names and types it expects; the client sends
data blocks in that format, then an empty block; the server confirms.

Example:
---
auto ins = conn.beginInsert("INSERT INTO trades (ts, sym, px) VALUES");
scope (failure) ins.abort();
foreach (t; trades)
    ins.addRow(t.ts, t.sym, t.px);   // sent in blocks of `maxBlockRows` rows
auto stats = ins.finish();
---

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.insert;

import std.datetime.date : Date;
import std.datetime.systime : SysTime;
import std.traits : isFloatingPoint, isIntegral, isSigned, isSomeString;
import std.typecons : Nullable;
import std.uuid : UUID;

import clickhoused.block : Block, readBlock, writeBlock;
import clickhoused.connection : Connection, QueryStats;
import clickhoused.exception : ClientException, ServerException;
import clickhoused.protocol.codes : ServerPacket;
import clickhoused.protocol.packets : readException, writeDataHeader;
import clickhoused.types.column : Column;
import clickhoused.types.factory : createColumn;
import clickhoused.types.parser : parseType;

/++
A running INSERT, created by `Connection.beginInsert`.

Add rows with `addRow` (buffered and sent in blocks automatically) or send
ready-made blocks with `send`; then call `finish`. The connection is busy
until `finish` or `abort` is called.

If the server reports an error while data is being sent, the next `addRow`,
`send` or `finish` throws a `clickhoused.exception.ServerException`; the
insert is then over and the connection stays usable. Rows sent before the
error may or may not have been stored, depending on the table engine and
settings.
+/
final class Inserter
{
    private Connection conn;
    private Block current;
    private size_t currentBytes;
    private bool endSent;
    private bool finished;

    /// Column names and types the server expects, in order. The data sent must match them.
    Block header;
    /// `addRow` sends the buffered rows when they reach this many rows...
    size_t maxBlockRows = 65_536;
    /// ... or approximately this many bytes.
    size_t maxBlockBytes = 16 * 1024 * 1024;
    /++
    Statistics; complete after `finish`. The server sends no progress for
    inserts over the native protocol, so `finish` sets `progress.writtenRows`
    to the number of rows sent (all of them were accepted if `finish` returns).
    +/
    QueryStats stats;
    /// Number of rows sent to the server so far.
    ulong rowsSent;

    /// Reads the server's reply to the INSERT query up to the header block.
    package this(Connection conn) @safe
    {
        this.conn = conn;
        conn.insertActive = true;
        auto r = conn.reader;
        bool acceptsNoData;
        conn.guarded({
            for (;;)
            {
                const packet = r.readUVarInt();
                switch (packet)
                {
                case ServerPacket.data:
                    header = conn.readDataBlock();
                    return;
                case ServerPacket.tableColumns:
                    r.readString();
                    r.readString();
                    break;
                case ServerPacket.exception:
                    auto e = readException(r);
                    markFinished();
                    throw e;
                case ServerPacket.endOfStream:
                    markFinished();
                    acceptsNoData = true;
                    return;
                default:
                    if (!conn.readInfoPacket(packet, stats))
                        throw Connection.unexpectedPacket(packet, "INSERT header");
                }
            }
        });
        // Outside `guarded`: the stream is intact and the connection stays usable
        if (acceptsNoData)
            throw new ClientException(
                    "The query does not accept INSERT data (inline VALUES and "
                    ~ "INSERT ... SELECT can be run with exec)");
    }

    /// Whether the insert is over (finished, aborted, or failed).
    @property bool isFinished() const @safe pure nothrow
    {
        return finished;
    }

    /// Creates an empty block with the columns the server expects, for filling and passing to `send`.
    Block newBlock() const @safe
    {
        auto block = new Block;
        foreach (h; header.columns)
            block.columns ~= createColumn(h.name, h.typeName, conn.server.timezone);
        return block;
    }

    /++
    Appends one row, one value per header column, in header order.

    Accepted value types: integers, floating-point numbers, `bool`, strings,
    `const(ubyte)[]`, `std.datetime.Date`, `std.datetime.SysTime`, `std.uuid.UUID`,
    D enums (stored by member name), `null` and `std.typecons.Nullable`.
    Values are converted to the column types with range checks.

    Rows are buffered and sent when `maxBlockRows` or `maxBlockBytes` is reached.

    Throws: `ClientException` if the number of values or a value does not fit
    the columns (the row is then not added); `ServerException` if the server
    reported an error.
    +/
    void addRow(Args...)(Args values) @safe
    {
        checkActive();
        if (values.length != header.columns.length)
            throw new ClientException("addRow got " ~ toText(
                    values.length) ~ " values, the INSERT has "
                    ~ toText(header.columns.length) ~ " columns");
        if (current is null)
            current = newBlock();
        const rows = current.rows;
        try
        {
            foreach (i, value; values)
            {
                appendValue(current.columns[i], value);
                currentBytes += estimateSize(value);
            }
        }
        catch (ClientException e)
        {
            foreach (c; current.columns)
                c.truncate(rows);
            throw e;
        }
        current.rows++;
        if (current.rows >= maxBlockRows || currentBytes >= maxBlockBytes)
            flush();
    }

    /// Sends the rows buffered by `addRow`, if any.
    void flush() @safe
    {
        checkActive();
        if (current is null || current.rows == 0)
            return;
        auto block = current;
        current = null;
        currentBytes = 0;
        send(block);
    }

    /++
    Sends a block of rows.

    The block must have the header's columns, matched by name in any order,
    with the same types. Blocks with no rows are ignored.

    Throws: `ClientException` if the block does not match the header (nothing
    is sent, and the insert stays active); `ServerException` if the server
    reported an error.
    +/
    void send(Block block) @safe
    {
        checkActive();
        auto ordered = matchHeader(block);
        if (ordered.rows == 0)
            return; // an empty block would end the insert
        conn.guarded({
            writeDataHeader(conn.writer);
            writeBlock(conn.blockWriter, ordered, conn.effectiveRevision);
            conn.flushBlock();
            rowsSent += ordered.rows;
            processPendingPackets();
        });
    }

    /++
    Sends the buffered rows and the end-of-data marker, and waits for the
    server to confirm the insert.

    Returns: statistics of the insert; `progress.writtenRows` is the number of rows inserted.
    Throws: `ServerException` if the insert failed on the server.
    +/
    QueryStats finish() @safe
    {
        flush();
        auto r = conn.reader;
        conn.guarded({
            conn.writeEndOfData();
            endSent = true;
            for (;;)
            {
                const packet = r.readUVarInt();
                switch (packet)
                {
                case ServerPacket.endOfStream:
                    markFinished();
                    if (stats.progress.writtenRows == 0)
                        stats.progress.writtenRows = rowsSent;
                    return;
                case ServerPacket.exception:
                    auto e = readException(r);
                    markFinished();
                    throw e;
                case ServerPacket.tableColumns:
                    r.readString();
                    r.readString();
                    break;
                default:
                    if (!conn.readInfoPacket(packet, stats))
                        throw Connection.unexpectedPacket(packet, "INSERT result");
                }
            }
        });
        return stats;
    }

    /++
    Abandons the insert by closing the connection. Rows already sent may have
    been stored. Does nothing if the insert is already over.
    +/
    void abort() @safe nothrow
    {
        if (!finished)
        {
            conn.close();
            finished = true;
            conn.insertActive = false;
        }
    }

    /// Handles messages the server sent while we were sending data, without blocking.
    private void processPendingPackets() @safe
    {
        auto r = conn.reader;
        while (r.buffered > 0 || conn.transport.dataAvailable())
        {
            const packet = r.readUVarInt();
            switch (packet)
            {
            case ServerPacket.exception:
                endAfterServerError(readException(r));
            case ServerPacket.tableColumns:
                r.readString();
                r.readString();
                break;
            default:
                if (!conn.readInfoPacket(packet, stats))
                    throw Connection.unexpectedPacket(packet, "INSERT progress");
            }
        }
    }

    /// Ends the insert after the server reported `error`, then throws it.
    private noreturn endAfterServerError(ServerException error) @safe
    {
        // The server discards data until the end marker; send it so the connection stays usable
        if (!endSent)
        {
            conn.writeEndOfData();
            endSent = true;
        }
        markFinished();
        throw error;
    }

    private Block matchHeader(Block block) const @safe
    {
        if (block.columns.length != header.columns.length)
            throw new ClientException("The block has " ~ toText(
                    block.columns.length) ~ " columns, the INSERT has "
                    ~ toText(header.columns.length));
        auto ordered = new Block;
        ordered.info = block.info;
        ordered.rows = block.rows;
        foreach (h; header.columns)
        {
            Column found;
            foreach (c; block.columns)
                if (c.name == h.name)
                {
                    found = c;
                    break;
                }
            if (found is null)
                throw new ClientException("The block has no column '" ~ h.name ~ "'");
            if (normalizedType(found.typeName) != normalizedType(h.typeName))
                throw new ClientException(
                        "Column '" ~ h.name ~ "' has type " ~ found.typeName
                        ~ ", the INSERT expects " ~ h.typeName);
            if (found.length != block.rows)
                throw new ClientException("Column '" ~ h.name ~ "' has " ~ toText(
                        found.length)
                        ~ " rows, the block has " ~ toText(block.rows));
            ordered.columns ~= found;
        }
        return ordered;
    }

    private void checkActive() const @safe
    {
        if (finished)
            throw new ClientException("The insert is already finished");
        if (!conn.isOpen)
            throw new ClientException("Connection is closed");
    }

    private void markFinished() @safe nothrow
    {
        finished = true;
        conn.insertActive = false;
        if (conn.state == Connection.State.busy)
            conn.state = Connection.State.ready;
    }
}

/++
Quotes a column or table name for use in SQL: `name` becomes `` `name` ``.
Backquotes and backslashes inside the name are escaped.
+/
string quoteIdentifier(string name) @safe pure
{
    string s = "`";
    foreach (char c; name)
    {
        if (c == '`' || c == '\\')
            s ~= '\\';
        s ~= c;
    }
    return s ~ "`";
}

///
@safe pure unittest
{
    assert(quoteIdentifier("price") == "`price`");
    assert(quoteIdentifier("a`b") == "`a\\`b`");
}

/// Appends `value` to `column` using the appender for its D type.
void appendValue(T)(Column column, T value) @safe
{
    import std.conv : to;
    import std.traits : Unqual;

    alias U = Unqual!T;
    static if (is(U == typeof(null)))
        column.appendNull();
    else static if (is(U : Nullable!V, V))
    {
        if (value.isNull)
            column.appendNull();
        else
            appendValue(column, value.get);
    }
    else static if (is(U == enum))
        column.appendString(value.to!string);
    else static if (is(U == bool))
        column.appendBool(value);
    else static if (isIntegral!U && isSigned!U)
        column.appendLong(value);
    else static if (isIntegral!U)
        column.appendUlong(value);
    else static if (isFloatingPoint!U)
        column.appendDouble(value);
    else static if (isSomeString!U)
        column.appendString(value.to!string);
    else static if (is(U : const(ubyte)[]))
        column.appendBytes(value);
    else static if (is(U == Date))
        column.appendDate(value);
    else static if (is(U == SysTime))
        column.appendSysTime(value);
    else static if (is(U == UUID))
        column.appendUUID(value);
    else
        static assert(0, "Cannot insert values of type " ~ T.stringof);
}

private size_t estimateSize(T)(T value) @safe pure nothrow
{
    static if (is(T == typeof(null)))
        return 1;
    else static if (is(T : const(char)[]) || is(T : const(ubyte)[]))
        return value.length + 8;
    else
        return 8;
}

private string toText(size_t n) @safe pure
{
    import std.conv : to;

    return n.to!string;
}

private string normalizedType(string typeName) @safe
{
    import clickhoused.exception : ProtocolException;

    try
        return parseType(typeName).toString();
    catch (ProtocolException)
        throw new ClientException("Invalid type name '" ~ typeName ~ "'");
}

version (unittest)
{
    import clickhoused.protocol.codes : ClientPacket, Revision;
    import clickhoused.protocol.testserver : ScriptedServer;
    import clickhoused.types.numeric : UInt8Column;
    import clickhoused.types.string : StringColumn;

    private Block insertHeader() @safe
    {
        auto b = new Block;
        b.columns = [new UInt8Column("x", "UInt8"), new StringColumn("s", "Nullable(String)")];
        b.columns[1].typeName = "Nullable(String)";
        return b;
    }
}

@safe unittest
{
    // Full insert against a scripted server; check the blocks the client sent
    auto s = new ScriptedServer;
    s.hello();
    auto conn = s.connect();

    s.tableColumns();
    s.block(ServerPacket.data, insertHeader());
    s.send();
    auto ins = conn.beginInsert("INSERT INTO t (x, s) VALUES");
    assert(ins.header.columns.length == 2 && conn.isBusy);
    s.transport.clearWritten();

    ins.addRow(1, "a");
    ins.addRow(2, null);
    ins.flush(); // sends the block; nothing is pending from the server yet
    s.progress(0, 2);
    s.endOfStream();
    s.send();
    const stats = ins.finish();
    assert(stats.progress.writtenRows == 2 && ins.isFinished && !conn.isBusy);

    auto out_ = s.clientOutput();
    assert(out_.readUVarInt() == ClientPacket.data && out_.readString() == "");
    auto sent = readBlock(out_, Revision.client);
    assert(sent.rows == 2 && sent.columns[0].getLong(1) == 2 && sent.columns[1].isNull(1));
    assert(out_.readUVarInt() == ClientPacket.data && out_.readString() == "");
    assert(readBlock(out_, Revision.client).rows == 0); // end marker
}

@safe unittest
{
    import std.exception : assertThrown, collectException;

    // Bad rows and blocks are rejected without breaking the insert; a server
    // error during sending ends it and keeps the connection usable
    auto s = new ScriptedServer;
    s.hello();
    auto conn = s.connect();
    s.block(ServerPacket.data, insertHeader());
    s.send();
    auto ins = conn.beginInsert("INSERT INTO t VALUES");

    assertThrown!ClientException(ins.addRow(1));
    assertThrown!ClientException(ins.addRow(300, "x")); // 300 does not fit UInt8
    assert(ins.current.rows == 0 && ins.current.columns[1].length == 0); // row rolled back
    auto wrong = new Block;
    wrong.columns = [new UInt8Column("x", "UInt8"), new UInt8Column("s", "UInt8")];
    assertThrown!ClientException(ins.send(wrong));
    assert(!ins.isFinished);

    s.exception(53, "Type mismatch");
    s.send();
    ins.addRow(1, "a");
    s.transport.clearWritten();
    const e = collectException!ServerException(ins.flush());
    assert(e !is null && e.code == 53);
    assert(ins.isFinished && conn.isOpen && !conn.isBusy);
    auto out_ = s.clientOutput();
    assert(out_.readUVarInt() == ClientPacket.data); // the client ended the insert after the error
}

@safe unittest
{
    import std.exception : assertThrown;

    // beginInsert on a query that does not take data
    auto s = new ScriptedServer;
    s.hello();
    auto conn = s.connect();
    s.endOfStream();
    s.send();
    assertThrown!ClientException(conn.beginInsert("INSERT INTO t VALUES (1)"));
    assert(conn.isOpen && !conn.isBusy);
}

@safe unittest
{
    import std.exception : assertThrown;

    // query() on an INSERT without data ends it cleanly and reports the misuse
    auto s = new ScriptedServer;
    s.hello();
    auto conn = s.connect();
    s.tableColumns();
    s.block(ServerPacket.data, insertHeader());
    s.endOfStream();
    s.send();
    assertThrown!ClientException(conn.exec("INSERT INTO t VALUES"));
    assert(conn.isOpen && !conn.isBusy);
}
