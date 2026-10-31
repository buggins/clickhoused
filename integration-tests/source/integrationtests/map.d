/// Map tests against a real server. All tables are session temporary tables.
module integrationtests.map;

import std.conv : to;
import std.exception : enforce;
import std.typecons : Nullable, Tuple, tuple;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer;

/// Maps of several key and value types: getString must equal the server's toString().
void testMapRead()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto block = conn.firstBlock(`SELECT
            map('a', 1, 'b', 2) AS m1, toString(m1),
            CAST(map() AS Map(String, UInt8)) AS m2, toString(m2),
            map(1, [1, 2], 2, []) AS m3, toString(m3),
            map('x', NULL, 'y', 'it''s') AS m4, toString(m4),
            map('k', map('n', 1)) AS m5, toString(m5),
            CAST(map('lc', 1) AS Map(LowCardinality(String), UInt8)) AS m6, toString(m6),
            map(toDate('2025-10-29'), toDecimal32('1.50', 2)) AS m7, toString(m7),
            [map('x', 1), map()] AS m8, toString(m8),
            tuple(map('t', toIPv4('1.2.3.4')), 1) AS m9, toString(m9)`);
    for (size_t i = 0; i < block.columns.length; i += 2)
    {
        auto c = block.columns[i];
        const ours = c.getString(0);
        const expected = block.columns[i + 1].getString(0);
        enforce(ours == expected, c.name ~ " (" ~ c.typeName ~ "): '" ~ ours ~ "', the server says '" ~ expected ~ "'");
    }
    enforce(readValue!(ubyte[string])(block.column("m1"), 0) == ["a": ubyte(1), "b": ubyte(2)], "associative array");
}

/// Many rows over several blocks, maps of varying size with LowCardinality keys.
void testMapManyRows()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    size_t rows;
    foreach (block; conn.query("SELECT number, CAST(mapFromArrays(arrayMap(x -> toString(x), range(number % 5)), "
            ~ "range(number % 5)) AS Map(LowCardinality(String), UInt64)) AS m FROM numbers(100000)",
            ["max_block_size": "8192"]))
    {
        auto numbers = block.column!UInt64Column("number").data;
        auto m = block.column("m");
        foreach (row; 0 .. block.rows)
        {
            const n = numbers[row];
            const values = readValue!(ulong[string])(m, row);
            enforce(values.length == n % 5, "row " ~ n.to!string ~ ": size");
            foreach (k; 0 .. n % 5)
                enforce(values[k.to!string] == k, "row " ~ n.to!string ~ ": value");
        }
        rows += block.rows;
    }
    enforce(rows == 100_000, "rows: " ~ rows.to!string);
}

/// Inserting maps from associative arrays, arrays of tuples and text; Map struct fields.
void testMapInsert()
{
    static struct Row
    {
        uint id;
        long[string] counts;
        Tuple!(string, Nullable!string)[] attrs; // keeps order and repeated keys
    }

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE map_ins (id UInt32, counts Map(String, Int64), "
            ~ "attrs Map(LowCardinality(String), Nullable(String))) ENGINE = Memory");
    auto ins = conn.beginInsert("INSERT INTO map_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, ["a": 1L], [tuple("k", Nullable!string("v")), tuple("k", Nullable!string.init)]);
    ins.addRow(2, "{'x': -5, 'y': 6}", cast(string[string]) null);
    ins.finish();
    conn.insert("map_ins", [Row(3, ["z": long.max], [tuple("p", Nullable!string("q"))])]);

    string[][] rows;
    foreach (block; conn.query("SELECT toString(counts), toString(attrs) FROM map_ins ORDER BY id"))
        foreach (r; 0 .. block.rows)
            rows ~= [block.columns[0].getString(r), block.columns[1].getString(r)];
    const string[][] expected = [
        ["{'a':1}", "{'k':'v','k':NULL}"], ["{'x':-5,'y':6}", "{}"],
        ["{'z':9223372036854775807}", "{'p':'q'}"],
    ];
    enforce(rows == expected, "rows: " ~ rows.to!string);

    const back = conn.queryRow!Row("SELECT * FROM map_ins WHERE id = 1");
    enforce(back.counts.length == 1 && back.counts["a"] == 1 && back.attrs.length == 2 && back.attrs[1][1].isNull,
            "struct round trip: " ~ back.to!string);
    const literal = conn.queryValue!string("SELECT toString(" ~ formatLiteral(["k": [1, 2]]) ~ ")");
    enforce(literal == "{'k':[1,2]}", "literal: " ~ literal);
}
