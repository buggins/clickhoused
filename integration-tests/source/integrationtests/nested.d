/// Nested column tests against a real server, with flatten_nested = 1 (the default) and 0. Tables are session temporary tables.
module integrationtests.nested;

import std.conv : to;
import std.exception : enforce;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer;

private struct Item
{
    ubyte a;
    string b;
}

/// All rows of `sql` as text, one string per cell.
private string[][] textRows(Connection conn, string sql)
{
    string[][] rows;
    foreach (block; conn.query(sql))
        foreach (r; 0 .. block.rows)
        {
            string[] row;
            foreach (c; block.columns)
                row ~= c.getString(r);
            rows ~= row;
        }
    return rows;
}

/// flatten_nested = 1: a Nested column is separate arrays `n.a` and `n.b`, inserted and read as arrays.
void testNestedFlattened()
{
    static struct Row
    {
        uint id;
        @column("n.a") ubyte[] a;
        @column("n.b") string[] b;
    }

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("SET flatten_nested = 1");
    conn.exec("CREATE TEMPORARY TABLE nested_flat (id UInt32, n Nested(a UInt8, b String)) ENGINE = Memory");
    auto ins = conn.beginInsert("INSERT INTO nested_flat VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, [ubyte(1), 2], ["x", "y"]);
    ins.addRow(2, "[]", "[]");
    ins.finish();
    conn.insert("nested_flat", [Row(3, [7], ["z"])]);

    auto header = conn.firstBlock("SELECT * FROM nested_flat WHERE id = 1");
    enforce(header.columns.length == 3 && header.columns[1].name == "n.a"
            && header.columns[1].typeName == "Array(UInt8)" && header.columns[2].typeName == "Array(String)",
            "flattened columns");
    const string[][] expected = [
        ["1", "[1,2]", "['x','y']"], ["2", "[]", "[]"], ["3", "[7]", "['z']"]
    ];
    const rows = conn.textRows("SELECT * FROM nested_flat ORDER BY id");
    enforce(rows == expected, "rows: " ~ rows.to!string);
    enforce(conn.queryRow!Row("SELECT * FROM nested_flat WHERE id = 1") == Row(1, [1, 2], ["x", "y"]),
            "struct with @column(\"n.a\")");
    const joined = conn.textRows("SELECT id, n.a, n.b FROM nested_flat ARRAY JOIN n ORDER BY id, n.a");
    enforce(joined == [["1", "1", "x"], ["1", "2", "y"], ["3", "7", "z"]], "ARRAY JOIN: " ~ joined.to!string);

    // The server checks that the arrays of one row have the same length; the connection stays usable
    bool failed;
    try
        conn.insert("nested_flat", [Row(4, [1, 2], ["only one"])]);
    catch (ServerException)
        failed = true;
    enforce(failed, "arrays of different lengths must be rejected");
    enforce(conn.queryValue!ulong("SELECT count() FROM nested_flat") == 3, "rows after the failed insert");
}

/// flatten_nested = 0: a Nested column keeps its type and is an array of named tuples (arrays of structs in D).
void testNestedWhole()
{
    static struct Row
    {
        uint id;
        Item[] n;
    }

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("SET flatten_nested = 0");
    conn.exec("CREATE TEMPORARY TABLE nested_tree (id UInt32, n Nested(a UInt8, b String)) ENGINE = Memory");

    auto ins = conn.beginInsert("INSERT INTO nested_tree VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, [Item(1, "x"), Item(2, "y")]);
    ins.addRow(2, "[(5,'it''s')]");
    ins.addRow(3, cast(Item[]) null);
    ins.finish();
    conn.insert("nested_tree", [Row(4, [Item(9, "w")])]);

    auto block = conn.firstBlock("SELECT n, toString(n) AS text, n.a, n.b FROM nested_tree WHERE id = 1");
    auto n = block.column("n");
    enforce(n.typeName == "Nested(a UInt8, b String)", "type name: " ~ n.typeName);
    enforce(n.getString(0) == block.column("text").getString(0), "text: " ~ n.getString(0));
    enforce(block.column("n.a").getString(0) == "[1,2]" && block.column("n.b").getString(0) == "['x','y']",
            "subcolumns");
    enforce(readValue!(Item[])(n, 0) == [Item(1, "x"), Item(2, "y")], "readValue!(Item[])");

    const rows = conn.textRows("SELECT id, toString(n) FROM nested_tree ORDER BY id");
    enforce(rows == [
        ["1", "[(1,'x'),(2,'y')]"], ["2", "[(5,'it\\'s')]"], ["3", "[]"], ["4", "[(9,'w')]"]
    ], "rows: " ~ rows.to!string);
    enforce(conn.queryRow!Row("SELECT * FROM nested_tree WHERE id = 4") == Row(4, [Item(9, "w")]),
            "struct round trip");

    // Nested inside Nested
    conn.exec("CREATE TEMPORARY TABLE nested_deep (id UInt32, n Nested(k String, tags Nested(t String, w Float64))) "
            ~ "ENGINE = Memory");
    conn.exec("INSERT INTO nested_deep VALUES (1, [('a', [('t1', 0.5)]), ('b', [])])");
    block = conn.firstBlock("SELECT n, toString(n) AS text FROM nested_deep");
    enforce(block.column("n").getString(0) == block.column("text").getString(0), "deep: " ~ block.column("n")
            .getString(0));
}
