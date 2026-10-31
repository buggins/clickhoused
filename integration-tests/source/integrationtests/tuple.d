/// Tuple tests against a real server. All tables are session temporary tables.
module integrationtests.tuple;

import std.conv : to;
import std.datetime.date : Date;
import std.exception : enforce;
import std.typecons : Nullable, Tuple, tuple;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer;

/// Plain, named and nested tuples: getString must equal the server's toString().
void testTupleRead()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto block = conn.firstBlock(`SELECT
            tuple(1, 'a') AS t1, toString(t1),
            CAST((1, 'x') AS Tuple(a UInt8, b String)) AS t2, toString(t2),
            tuple(tuple(1, NULL), [2, 3]) AS t3, toString(t3),
            tuple(toDate('2025-10-29'), 1.5, toUUID('00112233-4455-6677-8899-aabbccddeeff')) AS t4, toString(t4),
            CAST(('lc', 7) AS Tuple(LowCardinality(String), UInt8)) AS t5, toString(t5),
            [tuple(1, 'a'), tuple(2, 'b')] AS t6, toString(t6),
            tuple(toDecimal32('1.50', 2), toIPv6('::1'), toInt128(-1)) AS t7, toString(t7),
            tuple(1) AS t8, toString(t8)`);
    for (size_t i = 0; i < block.columns.length; i += 2)
    {
        auto c = block.columns[i];
        const ours = c.getString(0);
        const expected = block.columns[i + 1].getString(0);
        enforce(ours == expected, c.name ~ " (" ~ c.typeName ~ "): '" ~ ours ~ "', the server says '" ~ expected ~ "'");
    }
    auto named = block.column!TupleColumn("t2");
    enforce(named.isNamed && named.element("b").getString(0) == "x", "named element access");
}

/// Many rows over several blocks, with a LowCardinality element (its prefix passes through the tuple).
void testTupleManyRows()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    size_t rows;
    foreach (block; conn.query("SELECT number, CAST((number, toString(number % 100), range(number % 4)) "
            ~ "AS Tuple(n UInt64, s LowCardinality(String), r Array(UInt64))) AS t FROM numbers(100000)",
            ["max_block_size": "8192"]))
    {
        auto numbers = block.column!UInt64Column("number").data;
        auto t = block.column("t");
        foreach (row; 0 .. block.rows)
        {
            const v = readValue!(Tuple!(ulong, string, ulong[]))(t, row);
            const n = numbers[row];
            enforce(v[0] == n && v[1] == (n % 100).to!string && v[2].length == n % 4, "row " ~ n.to!string);
        }
        rows += block.rows;
    }
    enforce(rows == 100_000, "rows: " ~ rows.to!string);
}

/// Inserting tuples from structs, std.typecons.Tuple and text; struct fields mapped to tuple columns.
void testTupleInsert()
{
    static struct Point
    {
        double x;
        double y;
    }

    static struct Person
    {
        string name;
        ulong id;
    }

    static struct Row
    {
        uint id;
        Point p; // Tuple(Float64, Float64), by position
        Person who; // Tuple(id UInt64, name String), by name
        Tuple!(string, Nullable!int)[] items;
    }

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE tuple_ins (id UInt32, p Tuple(Float64, Float64), "
            ~ "who Tuple(id UInt64, name String), items Array(Tuple(String, Nullable(Int32)))) ENGINE = Memory");
    auto ins = conn.beginInsert("INSERT INTO tuple_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, Point(1.5, -2), Person("Ann", 7), [
        tuple("a", Nullable!int(1)), tuple("b", Nullable!int.init)
    ]);
    ins.addRow(2, "(0.25, 1e3)", "(8, 'Bob''s')", "[('c', NULL)]");
    ins.finish();
    conn.insert("tuple_ins", [Row(3, Point(0, 0), Person("Cy", 9), null)]);

    // The rows of two inserts may arrive in separate blocks
    string[][] rows;
    foreach (block; conn.query("SELECT toString(p), toString(who), toString(items) FROM tuple_ins ORDER BY id"))
        foreach (r; 0 .. block.rows)
            rows ~= [
            block.columns[0].getString(r), block.columns[1].getString(r),
            block.columns[2].getString(r)
    ];
    const string[][] expected = [
        ["(1.5,-2)", "(7,'Ann')", "[('a',1),('b',NULL)]"],
        ["(0.25,1000)", "(8,'Bob\\'s')", "[('c',NULL)]"],
        ["(0,0)", "(9,'Cy')", "[]"],
    ];
    enforce(rows == expected, "rows: " ~ rows.to!string);

    const back = conn.queryRow!Row("SELECT * FROM tuple_ins WHERE id = 1");
    enforce(back.p == Point(1.5, -2) && back.who.name == "Ann" && back.who.id == 7 && back.items.length == 2
            && back.items[1][1].isNull, "struct round trip: " ~ back.to!string);
    const literal = conn.queryValue!string("SELECT toString(" ~ formatLiteral(tuple(1, "a", [2])) ~ ")");
    enforce(literal == "(1,'a',[2])", "literal: " ~ literal);
}
