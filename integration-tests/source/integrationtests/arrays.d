/// Array(T) tests against a real server. All tables are session temporary tables.
module integrationtests.arrays;

import std.conv : to;
import std.datetime.date : Date;
import std.exception : enforce;
import std.typecons : Nullable;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer;

/// Arrays of every element type: getString must equal the server's toString().
void testArrayRead()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    // Each array column is followed by its toString(); old servers type literals
    // strictly, so the element types are spelled out with CAST
    auto block = conn.firstBlock(`SELECT
            CAST([1, 2, 3] AS Array(UInt8)) AS a1, toString(a1),
            CAST([-9223372036854775808, 0] AS Array(Int64)) AS a2, toString(a2),
            CAST([1.5, -0., inf, nan, 0.1] AS Array(Float32)) AS a3, toString(a3),
            CAST(['a''b', 'c\\d', 'e\nf', '\t\0x', ''] AS Array(String)) AS a4, toString(a4),
            [toFixedString('ab', 3)] AS a5, toString(a5),
            [toDate('2025-10-29'), toDate('1970-01-01')] AS a6, toString(a6),
            [toDate32('1900-01-01')] AS a7, toString(a7),
            [toDateTime('2025-10-29 12:00:00', 'Europe/Lisbon')] AS a8, toString(a8),
            [toDateTime64('2025-10-29 12:00:00.123', 3, 'Asia/Tokyo')] AS a9, toString(a9),
            [toUUID('00112233-4455-6677-8899-aabbccddeeff')] AS a10, toString(a10),
            CAST(['a', 'b'] AS Array(Enum8('a' = 1, 'b' = 2))) AS a11, toString(a11),
            [true, false] AS a12, toString(a12),
            CAST([1, NULL, 3] AS Array(Nullable(Int32))) AS a13, toString(a13),
            CAST([NULL, 'x'] AS Array(Nullable(String))) AS a14, toString(a14),
            CAST([[1, 2], [], [3]] AS Array(Array(Int16))) AS a15, toString(a15),
            CAST([] AS Array(String)) AS a16, toString(a16),
            [] AS a17, toString(a17),
            [toLowCardinality('lc')] AS a18, toString(a18)`);
    enforce(block.rows == 1, "rows");
    for (size_t i = 0; i < block.columns.length; i += 2)
    {
        auto array = block.columns[i];
        enforce(cast(ArrayColumn) array !is null, array.name ~ " (" ~ array.typeName ~ ") is not an ArrayColumn");
        const expected = block.columns[i + 1].getString(0);
        enforce(array.getString(0) == expected, array.name ~ " (" ~ array.typeName ~ "): '" ~ array.getString(
                0)
                ~ "', the server says '" ~ expected ~ "'");
    }
    enforce(block.column!ArrayColumn("a1").getBytes(0) == [1, 2, 3], "Array(UInt8) bytes");
}

/// Many rows with arrays of varying length, over several blocks.
void testArrayManyRows()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    size_t rows;
    foreach (block; conn.query(
            "SELECT number, range(number % 7) AS r, arrayMap(x -> toString(x), r) AS s "
            ~ "FROM numbers(100000)", ["max_block_size": "8192"]))
    {
        auto numbers = block.column!UInt64Column("number").data;
        foreach (row; 0 .. block.rows)
        {
            const n = numbers[row];
            auto r = readValue!(ulong[])(block.column("r"), row);
            auto s = readValue!(string[])(block.column("s"), row);
            enforce(r.length == n % 7 && s.length == r.length, "row " ~ n.to!string ~ ": length");
            foreach (k, v; r)
                enforce(v == k && s[k] == k.to!string, "row " ~ n.to!string ~ ": values");
        }
        rows += block.rows;
    }
    enforce(rows == 100_000, "rows: " ~ rows.to!string);
}

/// Inserting D arrays, array text and structs with array fields; reading them back.
void testArrayInsert()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE arr_ins (id UInt32, a Array(Int32), s Array(Nullable(String)), "
            ~ "n Array(Array(UInt8)), d Array(Date)) ENGINE = Memory");

    auto ins = conn.beginInsert("INSERT INTO arr_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, [1, -2, int.max], [Nullable!string("x"), Nullable!string.init], [[1, 2], [], [3]],
            [Date(2025, 10, 29)]);
    ins.addRow(2, cast(int[]) null, cast(string[]) null, cast(ubyte[][]) null, cast(Date[]) null);
    ins.addRow(3, "[4, 5]", "['it''s', NULL]", "[[255]]", "['1970-01-01']"); // text, parsed by the columns
    // A row that doesn't fit is rejected without leaving partial arrays behind
    enforce(collectClientException({
            ins.addRow(4, [1L, long.max], ["y"], [[1]], [Date(2025, 1, 1)]);
        }),
            "an out-of-range element should be rejected");
    ins.finish();

    auto block = conn.firstBlock(
            "SELECT id, a, s, n, d, toString(a), toString(s), toString(n), toString(d) "
            ~ "FROM arr_ins ORDER BY id");
    enforce(block.rows == 3, "rows: " ~ block.rows.to!string);
    const string[][] expected = [
        ["[1,-2,2147483647]", "['x',NULL]", "[[1,2],[],[3]]", "['2025-10-29']"],
        ["[]", "[]", "[]", "[]"],
        ["[4,5]", "['it\\'s',NULL]", "[[255]]", "['1970-01-01']"],
    ];
    foreach (row; 0 .. 3)
        foreach (k; 0 .. 4)
        {
            const ours = block.columns[1 + k].getString(row);
            const server = block.columns[5 + k].getString(row);
            enforce(ours == expected[row][k] && server == expected[row][k],
                    "row " ~ row.to!string ~ " column " ~ block.columns[1 + k].name ~ ": '" ~ ours ~ "' / '"
                    ~ server ~ "', expected '" ~ expected[row][k] ~ "'");
        }

    // Struct mapping both ways
    static struct Row
    {
        uint id;
        int[] a;
        Nullable!string[] s;
        ubyte[][] n;
        Date[] d;
    }

    conn.insert("arr_ins", [Row(10, [7], [Nullable!string("z")], [[9, 9]], [Date(2000, 2, 29)])]);
    const back = conn.queryRow!Row("SELECT * FROM arr_ins WHERE id = 10");
    enforce(back.a == [7] && back.s.length == 1 && back.s[0].get == "z" && back.n == [[9, 9]]
            && back.d == [Date(2000, 2, 29)], "struct round trip: " ~ back.to!string);
}

private bool collectClientException(scope void delegate() action)
{
    try
        action();
    catch (ClientException)
        return true;
    return false;
}
