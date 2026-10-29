/// Struct mapping and SQL literal tests against a real server.
module integrationtests.mapping;

import core.time : hnsecs, msecs;
import std.algorithm.comparison : equal;
import std.array : array;
import std.conv : to;
import std.datetime.date : Date, DateTime;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.exception : assertThrown, collectException, enforce;
import std.typecons : Nullable;
import std.uuid : UUID;

import clickhoused;
import integrationtests.server : connectToServer;

/// A D enum matching the table's Enum8 column by member name.
private enum Side
{
    buy,
    sell,
}

/// A struct exercising every kind of mapped field.
private struct Trade
{
    ulong id;
    @column("ts") SysTime time;
    string sym;
    double px;
    uint qty;
    Side side;
    Date day;
    UUID uid;
    Nullable!string note;
    bool flag;
    @ignore string cache;
}

/// Structs are inserted and read back unchanged.
void testStructRoundTrip()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec(`CREATE TEMPORARY TABLE trades (id UInt64, ts DateTime64(3, 'UTC'), sym LowCardinality(String),
            px Float64, qty UInt32, side Enum8('buy' = 1, 'sell' = 2), day Date, uid UUID, note Nullable(String),
            flag Bool, extra String DEFAULT 'x') ENGINE = Memory`);

    Trade[] trades;
    foreach (i; 0 .. 1000)
    {
        Trade t;
        t.id = i;
        t.time = SysTime(DateTime(2025, 10, 29, 12, 0, 0), UTC()) + (i * 1001).msecs;
        t.sym = i % 2 ? "AAPL" : "MSFT";
        t.px = 100.25 + i;
        t.qty = cast(uint)(i * 10);
        t.side = i % 3 ? Side.buy : Side.sell;
        t.day = Date(2025, 10, 29);
        t.uid = UUID("00112233-4455-6677-8899-aabbccddeeff");
        if (i % 5 == 0)
            t.note = "note " ~ i.to!string;
        t.flag = i % 2 == 0;
        t.cache = "not stored";
        trades ~= t;
    }
    const stats = conn.insert("trades", trades);
    enforce(stats.progress.writtenRows == 1000, "written rows");

    auto back = conn.query!Trade("SELECT * FROM trades ORDER BY id").array;
    enforce(back.length == 1000, "rows read: " ~ back.length.to!string);
    foreach (i, ref t; back)
    {
        auto expected = trades[i];
        expected.cache = null;
        enforce(t == expected, "row " ~ i.to!string ~ " differs: " ~ t.to!string ~ " vs " ~ expected.to!string);
    }

    const one = conn.queryRow!Trade("SELECT * FROM trades WHERE id = {id:UInt64}", null, ["id": "7"]);
    enforce(one.id == 7 && one.sym == "AAPL" && one.side == Side.buy, "queryRow");
    enforce(conn.queryValue!ulong("SELECT count() FROM trades") == 1000, "queryValue count");
    enforce(conn.queryValue!string("SELECT sym FROM trades WHERE id = 0") == "MSFT", "queryValue string");
    enforce(conn.queryValue!(Nullable!string)("SELECT note FROM trades WHERE id = 1").isNull, "queryValue NULL");
    enforce(conn.queryValue!Side("SELECT side FROM trades WHERE id = 0") == Side.sell, "queryValue enum");
    enforce(!conn.isBusy, "connection left busy");
}

/// Mapping errors are reported clearly and leave the connection usable where possible.
void testStructErrors()
{
    static struct Missing
    {
        ulong id;
        string nosuchcolumn;
    }

    static struct Small
    {
        ubyte v;
    }

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    assertThrown!ClientException(conn.query!Missing("SELECT number AS id FROM numbers(10)").array);
    enforce(conn.isOpen && !conn.isBusy, "state after a missing column");
    assertThrown!ClientException(conn.queryRow!Small("SELECT 1 AS v WHERE 0"));
    assertThrown!ClientException(conn.queryValue!ubyte("SELECT 300"));
    assertThrown!ClientException(conn.queryValue!long("SELECT NULL"));
    enforce(conn.isOpen && !conn.isBusy, "state after value errors");
    conn.ping();

    // An insert whose value does not fit is abandoned: the connection is closed
    conn.exec("CREATE TEMPORARY TABLE small (v UInt8) ENGINE = Memory");
    static struct Wide
    {
        long v;
    }

    assertThrown!ClientException(conn.insert("small", [Wide(1), Wide(1000)]));
    enforce(!conn.isOpen, "an abandoned insert should close the connection");
}

/// Literals from formatLiteral read back as the original values.
void testFormatLiteral()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();

    T roundTrip(T)(T value)
    {
        return conn.queryValue!T("SELECT " ~ formatLiteral(value) ~ " AS v");
    }

    foreach (s; ["", "plain", "it's", `back\slash`, "line\nbreak\ttab\r\0nul\x01ctl", "ünïcødé"])
        enforce(roundTrip(s) == s, "string " ~ formatLiteral(s));
    foreach (d; [0.1, -2.5, 1e300, double.min_normal, double.max])
        enforce(roundTrip(d) == d, "double " ~ formatLiteral(d));
    enforce(roundTrip(long.min) == long.min && roundTrip(ulong.max) == ulong.max, "integers");
    enforce(roundTrip(true) && !roundTrip(false), "booleans");
    const t = SysTime(DateTime(2025, 10, 29, 12, 34, 56), UTC()) + 1_234_567.hnsecs;
    enforce(roundTrip(t) == t, "SysTime " ~ formatLiteral(t));
    enforce(roundTrip(Date(2025, 10, 29)) == Date(2025, 10, 29), "Date");
    const u = UUID("00112233-4455-6677-8899-aabbccddeeff");
    enforce(roundTrip(u) == u, "UUID");
    enforce(roundTrip(Nullable!long.init).isNull, "NULL");
    enforce(conn.queryValue!string("SELECT arrayStringConcat(" ~ formatLiteral(["a", "b'c"]) ~ ", '|')") == "a|b'c",
            "array");
}
