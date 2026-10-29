/// INSERT tests against a real server. All tables are session temporary tables.
module integrationtests.insert;

import core.time : msecs;
import std.conv : to;
import std.datetime.date : Date, DateTime;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.exception : assertThrown, collectException, enforce;
import std.typecons : Nullable;
import std.uuid : UUID;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer;

/// Every supported type, inserted with addRow and read back.
void testInsertAllTypes()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec(`CREATE TEMPORARY TABLE ins_types (id UInt32, i8 Int8, u64 UInt64, f32 Float32, f64 Float64, b Bool,
            s String, fs FixedString(4), d Date, d32 Date32, dt DateTime('UTC'), dt64 DateTime64(3, 'Asia/Tokyo'),
            u UUID, e Enum8('a' = 1, 'b' = 2), ns Nullable(String), nu Nullable(UInt32),
            lc LowCardinality(String)) ENGINE = Memory`);

    auto ins = conn.beginInsert("INSERT INTO ins_types VALUES");
    scope (failure)
        ins.abort();
    enforce(ins.header.columns.length == 17, "header");
    const t = SysTime(DateTime(2025, 10, 29, 12, 34, 56), UTC());
    ins.addRow(1, -128, ulong.max, 1.5f, -2.25, true, "héllo", "ab", Date(2025, 10, 29), Date(1900, 1, 1), t,
            t + 789.msecs, UUID("00112233-4455-6677-8899-aabbccddeeff"), "b", "x", 42, "lc1");
    ins.addRow(2, 127, 0, 0.0, 0.0, false, "", "", Date(1970, 1, 1), Date(2299, 12, 31), SysTime.fromUnixTime(0, UTC()),
            "1969-12-31 23:59:59.5", UUID.init, "a", null, Nullable!int.init, "lc2");
    const stats = ins.finish();
    enforce(stats.progress.writtenRows == 2, "written rows: " ~ stats.progress.writtenRows.to!string);

    auto block = conn.firstBlock("SELECT * FROM ins_types ORDER BY id");
    string[] row(size_t r)
    {
        string[] values;
        foreach (c; block.columns)
            values ~= c.isNull(r) ? "NULL" : c.getString(r);
        return values;
    }

    const expected1 = [
        "1", "-128", "18446744073709551615", "1.5", "-2.25", "true", "héllo", "ab", "2025-10-29",
        "1900-01-01",
        "2025-10-29 12:34:56", "2025-10-29 21:34:56.789", "00112233-4455-6677-8899-aabbccddeeff", "b",
        "x",
        "42", "lc1",
    ];
    const expected2 = [
        "2", "127", "0", "0", "0", "false", "", "", "1970-01-01", "2299-12-31", "1970-01-01 00:00:00",
        "1969-12-31 23:59:59.500", // strings are parsed in the column timezone
        "00000000-0000-0000-0000-000000000000", "a", "NULL", "NULL", "lc2",
    ];
    enforce(row(0) == expected1, "row 1: " ~ row(0).to!string);
    enforce(row(1) == expected2, "row 2: " ~ row(1).to!string);
}

/// `Connection.insert` with a ready-made block whose columns are in a different order than the table's.
void testInsertBlock()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE ins_block (id UInt64, name String) ENGINE = Memory");

    auto names = new StringColumn("name");
    auto ids = new UInt64Column("id", "UInt64");
    foreach (i; 0 .. 1000)
    {
        ids.data ~= i;
        names.data ~= "n" ~ i.to!string;
    }
    auto block = new Block;
    block.columns = [names, ids]; // reversed
    block.rows = 1000;
    const stats = conn.insert("ins_block", block);
    enforce(stats.progress.writtenRows == 1000, "written rows");

    auto check = conn.firstBlock("SELECT count() AS c, sum(id) AS s, max(name) AS m FROM ins_block");
    enforce(check.column!UInt64Column("c").data == [1000]);
    enforce(check.column!UInt64Column("s").data == [499_500]);
    enforce(check.column!StringColumn("m").data == ["n999"]);
}

/// A streaming insert large enough to need many blocks; server messages are
/// processed between blocks.
void testLargeInsert()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE ins_large (id UInt64, s String) ENGINE = Memory");
    size_t profileEventBlocks;
    conn.onProfileEvents = (Block) @safe { profileEventBlocks++; };

    enum ulong n = 2_000_000;
    auto ins = conn.beginInsert("INSERT INTO ins_large VALUES");
    scope (failure)
        ins.abort();
    foreach (ulong i; 0 .. n)
        ins.addRow(i, "row");
    const stats = ins.finish();
    enforce(ins.rowsSent == n, "rows sent");
    enforce(stats.progress.writtenRows == n, "written rows: " ~ stats.progress.writtenRows.to!string);
    enforce(profileEventBlocks > 1, "expected profile events during the insert");

    auto check = conn.firstBlock("SELECT count() AS c, sum(id) AS s FROM ins_large");
    enforce(check.column!UInt64Column("c").data == [n]);
    enforce(check.column!UInt64Column("s").data == [n * (n - 1) / 2]);
}

/// Inserting a subset of the columns fills the others with their defaults.
void testInsertDefaults()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE ins_defaults (x UInt32, s String DEFAULT 'def', y UInt32 DEFAULT x * 2)
            ENGINE = Memory");
    auto ins = conn.beginInsert("INSERT INTO ins_defaults (x) VALUES");
    enforce(ins.header.columns.length == 1 && ins.header.columns[0].name == "x", "header");
    ins.addRow(21);
    ins.finish();
    auto block = conn.firstBlock("SELECT x, s, y FROM ins_defaults");
    enforce(block.column!StringColumn("s").data == ["def"] && block.column!UInt32Column("y").data == [
        42
    ]);
}

/// Error paths: the connection stays usable after each of them.
void testInsertErrors()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE ins_err (x UInt32, CONSTRAINT small CHECK x < 10) ENGINE = Memory");

    // Unknown table: rejected when the insert starts
    auto se = collectException!ServerException(conn.beginInsert("INSERT INTO no_such_table_xyz VALUES"));
    enforce(se !is null && se.code == 60, "expected UNKNOWN_TABLE (60)");
    conn.ping();

    // A block that does not match: rejected locally, nothing inserted
    auto wrong = new Block;
    auto col = new StringColumn("x");
    col.data = ["1"];
    wrong.columns = [col];
    wrong.rows = 1;
    assertThrown!ClientException(conn.insert("ins_err", wrong));
    conn.ping();

    // A value that does not fit the column: rejected by addRow, the insert continues
    auto ins = conn.beginInsert("INSERT INTO ins_err VALUES");
    assertThrown!ClientException(ins.addRow(-1));
    ins.addRow(5);
    ins.finish();

    // A row the server rejects (CHECK constraint): the error ends the insert
    ins = conn.beginInsert("INSERT INTO ins_err VALUES");
    ins.addRow(100);
    se = collectException!ServerException(ins.finish());
    enforce(se !is null && se.code == 469, "expected VIOLATED_CONSTRAINT (469)");
    enforce(ins.isFinished && conn.isOpen && !conn.isBusy);

    // exec() of an INSERT that needs data reports the misuse; inline VALUES work
    assertThrown!ClientException(conn.exec("INSERT INTO ins_err VALUES"));
    conn.exec("INSERT INTO ins_err VALUES (7)");
    auto block = conn.firstBlock("SELECT count() AS c, sum(x) AS s FROM ins_err");
    enforce(block.column!UInt64Column("c").data == [2] && block.column!UInt64Column("s")
            .data == [12],
            "rows in ins_err");
}
