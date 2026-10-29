/++
Column type tests against a real server.

Most tests select a value `v` together with `toString(v)` computed by the
server, and check that `Column.getString` produces exactly the server's text.
This covers decoding, timezone handling and formatting at once.
+/
module integrationtests.types;

import std.conv : to;
import std.datetime.date : Date, DateTime;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.exception : enforce;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer;

/// Runs `sql`, which must return columns `v` and `s` (`s` = `toString(v)`),
/// and checks `v`'s text against `s` row by row. Returns the number of rows.
size_t checkAgainstServerText(Connection conn, string sql)
{
    size_t rows;
    auto result = conn.query(sql);
    foreach (block; result)
    {
        auto v = block.columns[block.columnIndex("v")];
        auto s = block.columns[block.columnIndex("s")];
        foreach (row; 0 .. block.rows)
        {
            if (s.isNull(row))
                enforce(v.isNull(row), "row " ~ row.to!string ~ ": expected NULL in: " ~ sql);
            else
                enforce(v.getString(row) == s.getString(row),
                        "row " ~ row.to!string ~ ": '" ~ v.getString(
                        row) ~ "' != server's '" ~ s.getString(row)
                        ~ "' in: " ~ sql);
        }
        rows += block.rows;
    }
    enforce(rows > 0, "no rows returned by: " ~ sql);
    return rows;
}

/// Date, Date32, DateTime and DateTime64 in several timezones and precisions.
void testDateTimeTypes()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();

    conn.checkAgainstServerText(`SELECT toDate(arrayJoin(['1970-01-01', '2025-10-29', '2149-06-06'])) AS v,
            toString(v) AS s`);
    conn.checkAgainstServerText(`SELECT toDate32(arrayJoin(['1900-01-01', '1969-12-31', '2299-12-31'])) AS v,
            toString(v) AS s`);
    foreach (tz; ["UTC", "Europe/Lisbon", "Asia/Tokyo", "Asia/Kathmandu", "America/St_Johns"])
    {
        // Includes both sides of a DST change in Lisbon (2025-03-30 01:00 UTC)
        conn.checkAgainstServerText(`SELECT toDateTime(arrayJoin([0, 1743296399, 1743296400, 1761741296,
                4294967295]), '`
                ~ tz ~ `') AS v, toString(v) AS s`);
        conn.checkAgainstServerText(
                `SELECT fromUnixTimestamp64Milli(toInt64(arrayJoin(['-1', '0', '1761741296789'])), '`
                ~ tz ~ `') AS v, toString(v) AS s`);
    }
    conn.checkAgainstServerText(`SELECT fromUnixTimestamp64Micro(toInt64(arrayJoin(['-1', '1761741296123456'])),
            'UTC') AS v,
            toString(v) AS s`);
    conn.checkAgainstServerText(`SELECT fromUnixTimestamp64Nano(toInt64(arrayJoin(['-1', '0', '1761741296123456789'])),
            'Asia/Tokyo') AS v, toString(v) AS s`);
    conn.checkAgainstServerText(`SELECT toDateTime64('2025-10-29 12:34:56', 0, 'UTC') AS v, toString(v) AS s`);

    // Types without a timezone use the server timezone
    auto block = conn.firstBlock(`SELECT toDateTime(1761741296) AS v, toString(v) AS s`);
    auto dt = block.column!DateTimeColumn("v");
    enforce(dt.timezone == conn.serverInfo.timezone, "default timezone is not the server timezone");
    enforce(dt.getString(0) == block.column!StringColumn("s").data[0], "server-timezone formatting");

    // Exact points in time
    block = conn.firstBlock(`SELECT toDateTime('2025-10-29 12:34:56', 'Asia/Tokyo') AS t,
            toDateTime64('2025-10-29 12:34:56.789', 3, 'UTC') AS t64, toDate('2025-10-29') AS d`);
    enforce(block.column!DateTimeColumn("t")[0] == SysTime(DateTime(2025, 10, 29, 3, 34, 56), UTC()));
    enforce(block.column!DateTime64Column("t64")[0].toUnixTime == 1_761_741_296);
    enforce(block.column!DateColumn("d")[0] == Date(2025, 10, 29));
}

/// UUID values, including random ones.
void testUUID()
{
    import std.uuid : UUID;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.checkAgainstServerText(`SELECT toUUID('00112233-4455-6677-8899-aabbccddeeff') AS v, toString(v) AS s`);
    conn.checkAgainstServerText(`SELECT generateUUIDv4(number) AS v, toString(v) AS s FROM numbers(100)`);
    auto block = conn.firstBlock(`SELECT toUUID('00112233-4455-6677-8899-aabbccddeeff') AS v`);
    enforce(block.column!UUIDColumn("v").data[0] == UUID("00112233-4455-6677-8899-aabbccddeeff"));
}

/// Enum8 and Enum16, including extreme values.
void testEnums()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.checkAgainstServerText(`SELECT CAST(arrayJoin(['a', 'b', 'c']) AS Enum8('a' = -128, 'b' = 0, 'c' = 127))
            AS v, toString(v) AS s`);
    conn.checkAgainstServerText(`SELECT CAST(arrayJoin(['x', 'y']) AS Enum16('x' = -32768, 'y' = 32767)) AS v,
            toString(v) AS s`);
    auto block = conn.firstBlock(`SELECT CAST('b' AS Enum8('a' = 1, 'b' = 2)) AS v`);
    auto e = block.column!Enum8Column("v");
    enforce(e.data == [2] && e.label(0) == "b");
}

/// Nullable versions of the supported types, and a bare NULL.
void testNullable()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    const exprs = [
        "number", "toString(number)", "toDateTime(number, 'UTC')",
        "toFixedString(toString(number), 3)",
        "generateUUIDv4(number)", "CAST(number % 2 AS Enum8('even' = 0, 'odd' = 1))",
        "toDateTime64(number, 3, 'UTC')", "toDate32(number)", "number = 4",
    ];
    foreach (expr; exprs)
        conn.checkAgainstServerText(`SELECT if(number % 3 = 0, NULL, ` ~ expr ~ `) AS v, toString(v) AS s
                FROM numbers(7)`);

    auto block = conn.firstBlock(`SELECT NULL AS v, if(number = 1, NULL, number) AS n FROM numbers(2)`);
    auto v = block.columns[0];
    enforce(v.typeName == "Nullable(Nothing)" && v.isNullable && v.isNull(0) && v.isNull(1));
    auto n = block.column!NullableColumn("n");
    enforce(!n.isNull(0) && n.isNull(1));
    enforce((cast(UInt64Column) n.nested).data[0] == 0);
}

/// Per-cell getters and conversions on values from the server.
void testCellGetters()
{
    import std.exception : assertThrown;
    import std.uuid : UUID;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto block = conn.firstBlock(`SELECT toUInt64(5) AS u, -3 AS i, 2.5 AS f, '17' AS s, true AS b,
            toDate('2025-10-29') AS d, toDateTime('2025-10-29 12:34:56', 'UTC') AS t, NULL AS nul,
            toUUID('00112233-4455-6677-8899-aabbccddeeff') AS id`);
    Column c(string name)
    {
        return block.columns[block.columnIndex(name)];
    }

    enforce(c("u").getLong(0) == 5 && c("u").getDouble(0) == 5 && c("u").getString(0) == "5");
    enforce(c("i").getLong(0) == -3);
    assertThrown!ClientException(c("i").getUlong(0));
    enforce(c("f").getDouble(0) == 2.5);
    assertThrown!ClientException(c("f").getLong(0));
    enforce(c("s").getLong(0) == 17 && c("s").getString(0) == "17");
    enforce(c("b").getBool(0) && c("b").getLong(0) == 1);
    enforce(c("d").getDate(0) == Date(2025, 10, 29));
    enforce(c("t").getSysTime(0) == SysTime(DateTime(2025, 10, 29, 12, 34, 56), UTC()));
    enforce(c("t").getDate(0) == Date(2025, 10, 29));
    enforce(c("nul").isNull(0) && !c("nul").getVariant(0).hasValue);
    assertThrown!ClientException(c("nul").getLong(0));
    enforce(c("id").getUUID(0) == UUID("00112233-4455-6677-8899-aabbccddeeff"));
    assertThrown!ClientException(c("s").getSysTime(0));

    // getVariant holds the natural D type
    enforce(c("u").getVariant(0).get!ulong == 5);
    enforce(c("s").getVariant(0).get!string == "17");
    enforce(c("t").getVariant(0).get!SysTime.toUnixTime == 1_761_741_296);
}

/// Progress, profile events and server log callbacks.
void testCallbacks()
{
    import std.algorithm.searching : canFind;

    auto conn = connectToServer();
    scope (exit)
        conn.close();

    size_t progressCalls;
    ulong progressRows;
    conn.onProgress = (const Progress p) @safe { progressCalls++; progressRows += p.readRows; };
    string[] eventNames;
    string[] eventTypes;
    conn.onProfileEvents = (Block events) @safe {
        auto names = events.column!StringColumn("name");
        auto types = events.column!Enum8Column("type");
        foreach (row; 0 .. events.rows)
        {
            eventNames ~= names.data[row];
            eventTypes ~= types.label(row);
        }
    };
    string[] logLines;
    conn.onLog = (Block entries) @safe { logLines ~= entries.column!StringColumn("text").data; };

    const stats = conn.exec("SELECT sum(number) FROM numbers(1000000)", ["send_logs_level": "debug"]);
    enforce(progressCalls > 0 && progressRows == stats.progress.readRows, "progress callback");
    enforce(progressRows >= 1_000_000, "progress rows");
    enforce(eventNames.canFind("SelectedRows") || eventNames.length > 0, "no profile events");
    enforce(eventTypes.canFind("increment") || eventTypes.canFind("gauge"), "profile event types");
    enforce(logLines.length > 0, "no server log entries");
}
