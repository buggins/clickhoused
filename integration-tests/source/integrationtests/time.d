/// Time and Time64 tests against a real server (25.6+; skipped where the types are missing). Tables are session temporary tables.
module integrationtests.time;

import core.time : Duration, hours, minutes, msecs, seconds;
import std.conv : to;
import std.datetime.date : TimeOfDay;
import std.exception : enforce;
import std.typecons : Nullable;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer, hasType;

/// A connection with the Time types enabled, or null if the server doesn't have them.
private Connection timeConnection()
{
    auto conn = connectToServer();
    if (!conn.hasType("Time"))
    {
        conn.close();
        return null;
    }
    conn.exec("SET enable_time_time64_type = 1"); // off by default before 25.12
    return conn;
}

/// Raw values and text of Time and Time64(p) over the whole range, against the server's toString().
void testTimeRead()
{
    auto conn = timeConnection();
    if (conn is null)
        return;
    scope (exit)
        conn.close();

    size_t rows;
    foreach (block; conn.query(
            "SELECT toInt32(toInt64(sipHash64(number) % 7199999) - 3599999) AS s, CAST(s AS Time) AS t, "
            ~ "toString(t) AS tt FROM numbers(5000)"))
    {
        auto t = block.column!TimeColumn("t");
        auto s = block.column!Int32Column("s");
        auto tt = block.column("tt");
        enforce(t.typeName == "Time", t.typeName);
        foreach (r; 0 .. block.rows)
        {
            enforce(t.data[r] == s.data[r], "Time value of row " ~ r.to!string);
            enforce(t.getString(r) == tt.getString(r), "Time: '" ~ t.getString(
                    r) ~ "', the server says '"
                    ~ tt.getString(r) ~ "'");
        }
        rows += block.rows;
    }
    enforce(rows == 5000, "rows: " ~ rows.to!string);

    foreach (p; [0, 3, 6, 9])
    {
        const scale = "1" ~ "000000000"[0 .. p];
        const range = (3_600_000L * 10L ^^ p * 2 - 1).to!string;
        const half = (3_600_000L * 10L ^^ p - 1).to!string;
        foreach (block; conn.query("SELECT toInt64(sipHash64(number) % " ~ range ~ ") - " ~ half ~ " AS ticks, "
                ~ "CAST(toDecimal128(ticks, " ~ p.to!string ~ ") / " ~ scale ~ " AS Time64(" ~ p.to!string ~ ")) AS t, "
                ~ "toString(t) AS tt FROM numbers(2000)"))
        {
            auto t = block.column!Time64Column("t");
            auto ticks = block.column!Int64Column("ticks");
            auto tt = block.column("tt");
            enforce(t.precision == p && t.typeName == "Time64(" ~ p.to!string ~ ")", t.typeName);
            foreach (r; 0 .. block.rows)
            {
                enforce(t.data[r] == ticks.data[r], t.typeName ~ " value of row " ~ r.to!string);
                enforce(t.getString(r) == tt.getString(r), t.typeName ~ ": '" ~ t.getString(
                        r)
                        ~ "', the server says '" ~ tt.getString(r) ~ "'");
            }
        }
    }

    auto block = conn.firstBlock("SELECT CAST('-0:00:00.25' AS Time64(2)) AS a, CAST([1, -61] AS Array(Time)) AS b, "
            ~ "toString(b) AS bt, CAST(NULL AS Nullable(Time)) AS c, CAST(3723 AS Time) AS d, "
            ~ "tuple(CAST(1.5 AS Time64(1))) AS e, toString(e) AS et");
    enforce(block.column("a").getString(0) == "-00:00:00.25", "negative fraction");
    enforce(block.column("a").getDuration(0) == -250.msecs, "getDuration");
    enforce(block.column("b").getString(0) == block.column("bt").getString(0), "Array(Time) text");
    enforce(block.column("e").getString(0) == block.column("et").getString(0), "Tuple(Time64) text");
    enforce(block.column("c").isNull(0), "Nullable(Time)");
    enforce(readValue!TimeOfDay(block.column("d"), 0) == TimeOfDay(1, 2, 3), "readValue!TimeOfDay");
    enforce(readValue!(Duration[])(block.column("b"), 0) == [1.seconds, -61.seconds], "readValue!(Duration[])");
}

/// Inserting Time values from Duration, TimeOfDay, numbers and text; struct mapping.
void testTimeInsert()
{
    static struct Row
    {
        uint id;
        TimeOfDay t;
        Duration t3;
        Nullable!Duration n;
        Duration[] a;
    }

    auto conn = timeConnection();
    if (conn is null)
        return;
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE time_ins (id UInt32, t Time, t3 Time64(3), n Nullable(Time64(9)), "
            ~ "a Array(Time)) ENGINE = Memory");
    auto ins = conn.beginInsert("INSERT INTO time_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, TimeOfDay(9, 30, 0), 1500.msecs, -(25.hours + 1.seconds), [
        1.seconds, -90.minutes
    ]);
    ins.addRow(2, "999:59:59", "-0:00:00.5", "12:34:56.123456789", "['00:00:01','25:00:00']");
    ins.addRow(3, -3661, 2.5, null, cast(Duration[]) null);
    ins.finish();
    conn.insert("time_ins", [
        Row(4, TimeOfDay(23, 59, 59), -1.msecs, Nullable!Duration(0.seconds), [0.seconds])
    ]);

    string[][] rows;
    foreach (block; conn.query("SELECT toString(t), toString(t3), toString(n), toString(a) FROM time_ins ORDER BY id"))
        foreach (r; 0 .. block.rows)
        {
            string[] row;
            foreach (c; block.columns)
                row ~= c.isNull(r) ? "NULL" : c.getString(r);
            rows ~= row;
        }
    const string[][] expected = [
        ["09:30:00", "00:00:01.500", "-25:00:01.000000000", "['00:00:01','-01:30:00']"],
        ["999:59:59", "-00:00:00.500", "12:34:56.123456789", "['00:00:01','25:00:00']"],
        ["-01:01:01", "00:00:02.500", "NULL", "[]"],
        ["23:59:59", "-00:00:00.001", "00:00:00.000000000", "['00:00:00']"],
    ];
    enforce(rows == expected, "rows: " ~ rows.to!string);

    const back = conn.queryRow!Row("SELECT * FROM time_ins WHERE id = 1");
    enforce(back.t == TimeOfDay(9, 30, 0) && back.t3 == 1500.msecs && back.n.get == -(25.hours + 1.seconds)
            && back.a == [1.seconds, -90.minutes], "struct round trip: " ~ back.to!string);
}
