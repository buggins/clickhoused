/// LowCardinality(T) tests against a real server. All tables are session temporary tables.
module integrationtests.lowcardinality;

import std.conv : to;
import std.datetime.date : Date;
import std.exception : enforce;
import std.typecons : Nullable;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer;

/// LowCardinality of numbers and dates must be allowed explicitly.
private immutable string[string] suspicious;

shared static this()
{
    suspicious = ["allow_suspicious_low_cardinality_types": "1"];
}

/// LowCardinality of several inner types: getString must equal the server's toString().
void testLowCardinalityRead()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto block = conn.firstBlock(`SELECT
            toLowCardinality('it''s') AS c1, toString(c1),
            CAST(NULL AS LowCardinality(Nullable(String))) AS c2, 'NULL',
            CAST('x' AS LowCardinality(Nullable(String))) AS c3, toString(c3),
            CAST(toFixedString('ab', 3) AS LowCardinality(FixedString(3))) AS c4, toString(c4),
            CAST(4000000000 AS LowCardinality(UInt32)) AS c5, toString(c5),
            CAST(toDate('2025-10-29') AS LowCardinality(Date)) AS c6, toString(c6),
            CAST(['a', 'b', 'a'] AS Array(LowCardinality(String))) AS c7, toString(c7),
            CAST(['a', NULL] AS Array(LowCardinality(Nullable(String)))) AS c8, toString(c8),
            CAST([] AS Array(LowCardinality(String))) AS c9, toString(c9)`, suspicious);
    for (size_t i = 0; i < block.columns.length; i += 2)
    {
        auto c = block.columns[i];
        const ours = c.isNull(0) ? "NULL" : c.getString(0);
        const expected = block.columns[i + 1].getString(0);
        enforce(ours == expected, c.name ~ " (" ~ c.typeName ~ "): '" ~ ours ~ "', the server says '" ~ expected ~ "'");
    }
    enforce(cast(LowCardinalityColumn) block.columns[0]!is null, "not a LowCardinalityColumn");
    enforce(block.column!StringColumn("c1").data == ["it's"], "typed access to the values");
}

/// Many rows over several blocks, with more than 256 distinct values (16-bit indexes).
void testLowCardinalityManyRows()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    size_t rows;
    foreach (block; conn.query("SELECT number, toLowCardinality(toString(number % 1000)) AS s, "
            ~ "CAST(if(number % 5 = 0, NULL, toString(number % 7)) AS LowCardinality(Nullable(String))) AS n "
            ~ "FROM numbers(100000)", ["max_block_size": "8192"]))
    {
        auto numbers = block.column!UInt64Column("number").data;
        auto s = block.column("s");
        auto n = block.column("n");
        foreach (row; 0 .. block.rows)
        {
            const k = numbers[row];
            enforce(s.getString(row) == (k % 1000).to!string, "row " ~ k.to!string ~ ": s");
            enforce(k % 5 == 0 ? n.isNull(row) : n.getString(row) == (k % 7).to!string, "row " ~ k.to!string ~ ": n");
        }
        rows += block.rows;
    }
    enforce(rows == 100_000, "rows: " ~ rows.to!string);
}

/// Native inserts into LowCardinality columns, also inside arrays and with NULLs.
void testLowCardinalityInsert()
{
    enum Color
    {
        red,
        green
    }

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE lc_ins (id UInt32, s LowCardinality(String), "
            ~ "n LowCardinality(Nullable(String)), a Array(LowCardinality(String)), u LowCardinality(UInt64), "
            ~ "d LowCardinality(Date)) ENGINE = Memory", suspicious);
    auto ins = conn.beginInsert("INSERT INTO lc_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, "a", "x", ["p", "q", "p"], 7, Date(2025, 10, 29));
    ins.addRow(2, Color.green, null, cast(string[]) null, ulong.max, Date(1970, 1, 1));
    foreach (i; 3 .. 20_003) // many rows, 500 distinct values per column
        ins.addRow(i, (i % 500).to!string, i % 3 ? Nullable!string((i % 500)
                .to!string) : Nullable!string.init,
                [(i % 2).to!string], i % 500, Date(2000, 1, 1));
    ins.finish();

    auto block = conn.firstBlock("SELECT id, s, n, a, u, d FROM lc_ins WHERE id <= 2 ORDER BY id");
    string[] row(size_t r)
    {
        string[] values;
        foreach (c; block.columns)
            values ~= c.isNull(r) ? "NULL" : c.getString(r);
        return values;
    }

    enforce(row(0) == ["1", "a", "x", "['p','q','p']", "7", "2025-10-29"], "row 1: " ~ row(0).to!string);
    enforce(row(1) == ["2", "green", "NULL", "[]", "18446744073709551615", "1970-01-01"], "row 2: " ~ row(1).to!string);
    const counts = conn.firstBlock(
            "SELECT count(), uniqExact(s), countIf(n IS NULL), sum(length(a)), sum(u) "
            ~ "FROM lc_ins WHERE id > 2");
    string[] summary;
    foreach (c; counts.columns)
        summary ~= c.getString(0);
    enforce(summary == ["20000", "500", "6667", "20000", "4990000"], "summary: " ~ summary.to!string);

    // Struct mapping: enums by label, strings, Nullable
    static struct Row
    {
        uint id;
        Color s;
        Nullable!string n;
    }

    const back = conn.queryRow!Row("SELECT id, s, n FROM lc_ins WHERE id = 2");
    enforce(back.s == Color.green && back.n.isNull, "struct mapping: " ~ back.to!string);
}
