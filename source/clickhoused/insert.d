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

import core.time : Duration;
import std.bigint : BigInt, toDecimalString;
import std.datetime.date : Date, TimeOfDay;
import std.datetime.systime : SysTime;
import std.traits : isAssociativeArray, isDynamicArray, isFloatingPoint, isInstanceOf, isIntegral, isSigned,
    isSomeString;
import std.meta : AliasSeq;
import std.typecons : Nullable;
import std.json : JSONValue;
import std.uuid : UUID;
import std.variant : Variant;

import clickhoused.block : Block, readBlock, writeBlock;
import clickhoused.connection : Connection, QueryStats;
import clickhoused.exception : ClientException, ServerException;
import clickhoused.protocol.codes : ServerPacket;
import clickhoused.protocol.packets : readException, writeDataHeader;
import clickhoused.types.decimal : Decimal, appendDecimalTo;
import clickhoused.types.ip : IPv4, IPv4Column, IPv6, IPv6Column;
import clickhoused.types.wideint : isWideInt, WideIntColumn;
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
    private TypeInfo structType; // the struct type `structPositions` was computed for
    private size_t[] structPositions;
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
    `const(ubyte)[]`, `std.datetime.Date`, `std.datetime.SysTime`, `core.time.Duration` and
    `std.datetime.TimeOfDay` (for `Time` and `Time64`), `std.uuid.UUID`,
    D enums (stored by member name), `Int128`/`UInt128`/`Int256`/`UInt256`,
    `std.bigint.BigInt`, `Decimal`, `IPv4`, `IPv6`, structs and `std.typecons.Tuple` (for
    `Tuple` columns), associative arrays (for `Map` columns), `std.json.JSONValue` (as JSON text),
    `std.variant.Variant` (its held value,
    see `appendVariant`), `null`, `std.typecons.Nullable`, and
    dynamic arrays of these for `Array` columns (`[1, 2]`, `["a"]`, `[[1], []]`).
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

    /++
    Appends one row from the mapped fields of a struct (see `clickhoused.mapping`).
    Fields are matched to the INSERT's columns by name; every column must
    have a field.

    Throws: `ClientException` if the struct does not match the columns or a
    value does not fit (the row is then not added); `ServerException` if the
    server reported an error.
    +/
    void addStruct(T)(auto ref const T value) @safe if (is(T == struct))
    {
        import clickhoused.mapping : IgnoreField, columnNames;
        import std.traits : hasUDA;

        checkActive();
        if (current is null)
            current = newBlock();
        if (structType !is typeid(T))
        {
            structPositions = bindStruct(columnNames!T, T.stringof);
            structType = typeid(T);
        }
        const rows = current.rows;
        try
        {
            size_t k;
            static foreach (i; 0 .. T.tupleof.length)
            {
                static if (!hasUDA!(T.tupleof[i], IgnoreField))
                {
                    appendValue(current.columns[structPositions[k++]], value.tupleof[i]);
                    currentBytes += estimateSize(value.tupleof[i]);
                }
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

    /// The header position of each struct column; every header column must be covered.
    private size_t[] bindStruct(const string[] names, string typeName) const @safe
    {
        size_t[] positions;
        auto covered = new bool[header.columns.length];
        foreach (name; names)
        {
            size_t pos = size_t.max;
            foreach (i, h; header.columns)
                if (h.name == name)
                    pos = i;
            if (pos == size_t.max)
                throw new ClientException("The INSERT has no column '" ~ name ~ "' for a field of " ~ typeName);
            positions ~= pos;
            covered[pos] = true;
        }
        foreach (i, h; header.columns)
            if (!covered[i])
                throw new ClientException(typeName ~ " has no field for column '" ~ h.name ~ "'");
        return positions;
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
Appends the value held by `value` as `appendValue` does for its D type: an
empty `Variant` as NULL, integers, floating-point numbers, `bool`, strings,
`Date`, `SysTime`, `UUID`, `Duration` and `TimeOfDay`.

Throws: `ClientException` for other held types.
+/
void appendVariant(Column column, Variant value) @trusted
{
    // std.variant is not annotated @safe; peeking at a held value is memory-safe
    if (!value.hasValue)
        return column.appendNull();
    static foreach (V; AliasSeq!(long, int, short, byte, ulong, uint, ushort, ubyte, double, float, bool, string,
            const(char)[], Date, SysTime, UUID, Duration, TimeOfDay, JSONValue))
        if (auto p = value.peek!V)
            return appendValue(column, *p);
    throw new ClientException("Cannot store a Variant holding " ~ value.type.toString() ~ " in column '"
            ~ column.name ~ "' (" ~ column.typeName ~ ")");
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
void appendValue(T)(Column column, auto ref T value) @safe
{
    import std.conv : to;
    import std.traits : Unqual;

    alias U = Unqual!T;
    // Values without a typed Column append go to the Variant alternative that takes them, not to its String
    static if (!(is(U == typeof(null)) || isInstanceOf!(Nullable, U) || is(U == Variant) || is(U == enum)
            || is(U == bool) || isIntegral!U || isFloatingPoint!U || isSomeString!U || is(U
            : const(ubyte)[])
            || is(U == Date) || is(U == SysTime) || is(U == UUID) || is(U == Duration) || is(U == TimeOfDay)))
    {
        import clickhoused.types.dynamic : DynamicColumn;
        import clickhoused.types.variant : VariantColumn;

        if (auto variant = cast(VariantColumn) column)
            return variant.appendToAny((Column c) => appendValue(c, value));
        if (auto dynamic = cast(DynamicColumn) column)
            return dynamic.appendTyped(dynamicTypeOf(value), (Column c) => appendValue(c, value));
    }
    static if (is(U == typeof(null)))
        column.appendNull();
    else static if (is(U == Variant))
        (() @trusted => appendVariant(column, value))(); // copying a Variant is memory-safe
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
    else static if (isDynamicArray!U)
    {
        import clickhoused.types.array : ArrayColumn;

        import clickhoused.types.map : MapColumn;

        auto array = cast(ArrayColumn) column;
        if (array is null)
            if (auto map = cast(MapColumn) column)
                array = map.entries; // an array of (key, value) tuples fills a Map
        if (array is null)
            throw new ClientException("Cannot store an array in column '" ~ column.name ~ "' (" ~ column.typeName
                    ~ ")");
        const before = array.elements.length;
        scope (failure)
            array.elements.truncate(before); // leave the column as it was
        foreach (ref element; value)
            appendValue(array.elements, element);
        array.endRow();
    }
    else static if (is(U == Date))
        column.appendDate(value);
    else static if (is(U == SysTime))
        column.appendSysTime(value);
    else static if (is(U == UUID))
        column.appendUUID(value);
    else static if (is(U == Duration))
        column.appendDuration(value);
    else static if (is(U == TimeOfDay))
        column.appendDuration(value - TimeOfDay(0, 0, 0));
    else static if (is(U == JSONValue))
        column.appendString(value.toString()); // JSON text, parsed by the server
    else static if (isWideInt!U)
    {
        if (auto wide = cast(WideIntColumn!U) column)
            wide.data ~= value;
        else
            column.appendString(value.toString()); // other columns parse the decimal text, with range checks
    }
    else static if (is(U == BigInt))
        column.appendString(value.toDecimalString());
    else static if (is(U == IPv4))
    {
        if (auto typed = cast(IPv4Column) column)
            typed.appendIPv4(value);
        else
            column.appendString(value.toString()); // an IPv6 column stores it IPv4-mapped
    }
    else static if (is(U == IPv6))
    {
        if (auto typed = cast(IPv6Column) column)
            typed.appendIPv6(value);
        else
            column.appendString(value.toString());
    }
    else static if (is(U == Decimal))
    {
        if (!appendDecimalTo(column, value))
            column.appendString(value.toString()); // other numeric columns parse the text
    }
    else static if (isAssociativeArray!U)
    {
        import clickhoused.types.map : MapColumn;

        auto map = cast(MapColumn) column;
        if (map is null)
            throw new ClientException("Cannot store an associative array in column '" ~ column.name ~ "' ("
                    ~ column.typeName ~ "): it needs a Map column");
        const before = map.keys.length;
        scope (failure)
        {
            map.keys.truncate(before); // leave the column as it was
            map.values.truncate(before);
        }
        foreach (key, item; value)
        {
            appendValue(map.keys, key);
            appendValue(map.values, item);
        }
        map.endRow();
    }
    else static if (is(U == struct))
    {
        import clickhoused.mapping : IgnoreField, columnNames;
        import clickhoused.types.tuple : TupleColumn;
        import std.traits : hasUDA;

        auto tuple = cast(TupleColumn) column;
        if (tuple is null)
            throw new ClientException("Cannot store a " ~ U.stringof ~ " in column '" ~ column.name ~ "' ("
                    ~ column.typeName ~ "): it needs a Tuple column");
        const positions = tuple.fieldPositions(columnNames!U, U.stringof);
        const before = tuple.length;
        scope (failure)
            tuple.truncate(before); // leave the column as it was
        size_t k;
        static foreach (i; 0 .. U.tupleof.length)
        {
            static if (!hasUDA!(U.tupleof[i], IgnoreField))
                appendValue(tuple.elements[positions[k++]], value.tupleof[i]);
        }
        tuple.endRow();
    }
    else
        static assert(0, "Cannot insert values of type " ~ T.stringof);
}

/++
The type a value of D type `T` gets in a `Dynamic` column when it has no
typed append (arrays, structs, `Decimal`, ...): `Array(...)` of the element
type, `Map(K, V)`, a named `Tuple` for a struct, `Decimal(P, S)` with the
smallest precision that fits the value.
+/
string dynamicTypeOf(T)(auto ref const T value) @safe
{
    import std.traits : Unqual;

    alias U = Unqual!T;
    static if (is(U == Decimal))
    {
        import std.algorithm.comparison : max;

        const text = value.unscaled.toString();
        const digits = text.length - (text[0] == '-' ? 1 : 0);
        const needed = max(digits, value.scale, 1);
        const precision = needed <= 9 ? 9 : needed <= 18 ? 18 : needed <= 38 ? 38 : 76;
        return "Decimal(" ~ toText(precision) ~ ", " ~ toText(value.scale) ~ ")";
    }
    else
    {
        enum name = dynamicTypeName!U();
        static if (name is null)
            throw new ClientException(
                    "No ClickHouse type for " ~ T.stringof
                    ~ " in a Dynamic column; use DynamicColumn.appendTyped");
        else
            return name;
    }
}

/// ditto, for types whose ClickHouse type doesn't depend on the value; `null` if there is none.
private string dynamicTypeName(T)() @safe pure
{
    import std.traits : hasUDA, KeyType, Unqual, ValueType;
    import std.typecons : StdTuple = Tuple;
    import clickhoused.mapping : columnNames, IgnoreField, isTupleValue;
    import clickhoused.types.geo : GeoPoint;

    alias U = Unqual!T;
    static if (is(U == enum))
        return "String"; // stored by member name
    else static if (is(U == bool))
        return "Bool";
    else static if (isIntegral!U)
        return isSigned!U ? "Int64" : "UInt64";
    else static if (isFloatingPoint!U)
        return "Float64";
    else static if (isSomeString!U || is(U : const(ubyte)[]))
        return "String";
    else static if (is(U : Nullable!V, V))
        return wrap("Nullable(", dynamicTypeName!V(), ")");
    else static if (is(U == Date))
        return "Date32";
    else static if (is(U == SysTime))
        return "DateTime64(9)";
    else static if (is(U == UUID) || is(U == IPv4) || is(U == IPv6))
        return U.stringof;
    else static if (isWideInt!U)
        return U.typeName;
    else static if (is(U == BigInt))
        return "Int256";
    else static if (is(U == GeoPoint))
        return "Point";
    else static if (is(U == JSONValue))
        return "JSON";
    else static if (isDynamicArray!U)
        return wrap("Array(", dynamicTypeName!(typeof(U.init[0]))(), ")");
    else static if (isAssociativeArray!U)
    {
        const key = dynamicTypeName!(KeyType!U)();
        return key is null ? null : wrap("Map(" ~ key ~ ", ", dynamicTypeName!(ValueType!U)(), ")");
    }
    else static if (isInstanceOf!(StdTuple, U))
    {
        string s = "Tuple(";
        static foreach (i, F; U.Types)
        {
            if (dynamicTypeName!F() is null)
                return null;
            s ~= (i ? ", " : "") ~ (U.fieldNames[i].length ? "`" ~ U.fieldNames[i] ~ "` " : "") ~ dynamicTypeName!F();
        }
        return s ~ ")";
    }
    else static if (isTupleValue!U)
    {
        string s = "Tuple(";
        size_t k;
        static foreach (i; 0 .. U.tupleof.length)
        {
            static if (!hasUDA!(U.tupleof[i], IgnoreField))
            {
                if (dynamicTypeName!(typeof(U.tupleof[i]))() is null)
                    return null;
                s ~= (k ? ", " : "") ~ "`" ~ columnNames!U[k] ~ "` " ~ dynamicTypeName!(typeof(U.tupleof[i]))();
                k++;
            }
        }
        return s ~ ")";
    }
    else
        return null;
}

/// `open ~ inner ~ close`, or `null` if `inner` is.
private string wrap(string open, string inner, string close) @safe pure
{
    return inner is null ? null : open ~ inner ~ close;
}

private size_t estimateSize(T)(auto ref T value) @safe pure nothrow
{
    import std.traits : Unqual;

    static if (is(T == typeof(null)))
        return 1;
    else static if (is(Unqual!T == Variant))
        return 16; // std.variant is neither pure nor nothrow
    else static if (isDynamicArray!T && is(Unqual!(typeof(T.init[0])) == Variant))
        return 8 + value.length * 16;
    else static if (is(T : const(char)[]) || is(T : const(ubyte)[]))
        return value.length + 8;
    else static if (isAssociativeArray!T)
        return 8 + value.length * 16; // a rough estimate: iterating an associative array is not nothrow
    else static if (isDynamicArray!T)
    {
        size_t size = 8;
        foreach (ref element; value)
            size += estimateSize(element);
        return size;
    }
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
