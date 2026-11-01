/// Variant and Geometry tests against a real server (24.1+; skipped where the types are missing). Tables are session temporary tables.
module integrationtests.variant;

import std.conv : to;
import std.datetime.date : Date;
import std.exception : enforce;
import std.typecons : Nullable;
import std.variant : Variant;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer, hasType;

/// A connection where Variant tables can be created, or null if the server doesn't have the type.
private Connection variantConnection()
{
    auto conn = connectToServer();
    if (!conn.hasType("Variant"))
    {
        conn.close();
        return null;
    }
    conn.exec("SET allow_experimental_variant_type = 1"); // needed before 25.3
    return conn;
}

/// Every cell of `values` must print as its neighbour `text` (the server's toString()), and report the
/// same alternative as `kind` (the server's variantType()).
private void checkRows(Connection conn, string sql)
{
    foreach (block; conn.query(sql))
    {
        auto v = cast(VariantColumn) block.column("v");
        enforce(v !is null, "not a VariantColumn: " ~ block.column("v").typeName);
        auto text = block.column("text");
        auto kind = block.column("kind");
        foreach (r; 0 .. block.rows)
        {
            const expectedKind = kind.getString(r);
            const gotKind = v.isNull(r) ? "None" : v.variantTypeName(r);
            enforce(gotKind == expectedKind, "row " ~ r.to!string ~ ": alternative " ~ gotKind ~ ", the server says "
                    ~ expectedKind);
            if (!v.isNull(r))
                enforce(v.getString(r) == text.getString(r), "row " ~ r.to!string ~ ": '" ~ v.getString(
                        r)
                        ~ "', the server says '" ~ text.getString(r) ~ "'");
        }
    }
}

/// Reading Variant values of many kinds, NULLs, and Variant inside Array, Tuple and Map.
void testVariantRead()
{
    auto conn = variantConnection();
    if (conn is null)
        return;
    scope (exit)
        conn.close();
    enum type = "Variant(LowCardinality(String), UInt64, Float64, UUID, Array(UInt8), Tuple(a UInt8, b String), "
        ~ "DateTime64(3, 'UTC'))";
    conn.exec("CREATE TEMPORARY TABLE variant_read (id UInt32, v " ~ type ~ ") ENGINE = Memory");
    conn.exec("INSERT INTO variant_read VALUES (1, 'text'::LowCardinality(String)), (2, 42::UInt64), (3, NULL), "
            ~ "(4, 2.5::Float64), (5, '00112233-4455-6677-8899-aabbccddeeff'::UUID), (6, [1, 2]::Array(UInt8)), "
            ~ "(7, (3, 'x')::Tuple(a UInt8, b String)), "
            ~ "(8, 'lc'::LowCardinality(String)), (9, '2020-01-02 03:04:05.678'::DateTime64(3, 'UTC')), "
            ~ "(10, 'it''s'::LowCardinality(String))");
    conn.checkRows("SELECT v, toString(v) AS text, variantType(v) AS kind FROM variant_read ORDER BY id");

    // Many rows, so the alternatives' values interleave across reads
    conn.exec(
            "INSERT INTO variant_read SELECT 100 + number, multiIf(number % 3 = 0, toLowCardinality(toString(number))::"
            ~ type ~ ", number % 3 = 1, number::" ~ type ~ ", NULL) FROM numbers(30000)");
    conn.checkRows("SELECT v, toString(v) AS text, variantType(v) AS kind FROM variant_read ORDER BY id");

    auto block = conn.firstBlock("SELECT [v, NULL] AS a, toString(a) AS at, tuple(v, 1) AS t, toString(t) AS tt, "
            ~ "map('k', v) AS m, toString(m) AS mt FROM variant_read WHERE id IN (1, 6) ORDER BY id");
    foreach (r; 0 .. block.rows)
        foreach (pair; [["a", "at"], ["t", "tt"], ["m", "mt"]])
            enforce(block.column(pair[0]).getString(r) == block.column(pair[1]).getString(r), pair[0] ~ ": '"
                    ~ block.column(pair[0])
                        .getString(r) ~ "', the server says '"
                    ~ block.column(pair[1]).getString(r) ~ "'");

    block = conn.firstBlock("SELECT v FROM variant_read WHERE id IN (2, 3, 6) ORDER BY id");
    auto v = block.column("v");
    enforce(v.getLong(0) == 42 && readValue!Variant(v, 0).get!ulong == 42, "UInt64 alternative");
    enforce(!readValue!Variant(v, 1).hasValue && readValue!(Nullable!long)(v, 1).isNull, "NULL");
    enforce(readValue!(ubyte[])(v, 2) == [1, 2], "Array alternative as ubyte[]");
}

/// Inserting Variant values: generic appends, text, std.variant.Variant, arrays and structs.
void testVariantInsert()
{
    static struct Pair
    {
        ubyte a;
        string b;
    }

    static struct Row
    {
        uint id;
        Variant v;
    }

    auto conn = variantConnection();
    if (conn is null)
        return;
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE variant_ins (id UInt32, v Variant(String, Int64, Float64, Date, Array(UInt8), "
            ~ "Tuple(a UInt8, b String)), a Array(Variant(String, UInt64))) ENGINE = Memory");
    auto ins = conn.beginInsert("INSERT INTO variant_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, 5, "[1, 'x', NULL]");
    ins.addRow(2, "text", [Variant(7), Variant("y")]);
    ins.addRow(3, 2.5, "[]");
    ins.addRow(4, Date(2020, 1, 2), "[]");
    ins.addRow(5, [ubyte(1), 2], "[]");
    ins.addRow(6, Pair(3, "z"), "[]");
    ins.addRow(7, null, "[]");
    ins.finish();
    conn.insert("variant_ins", [Row(8, Variant(9L)), Row(9, Variant.init)]);

    string[][] rows;
    foreach (block; conn.query(
            "SELECT id, variantType(v), if(isNull(v), 'NULL', toString(v)), toString(a) FROM variant_ins "
            ~ "ORDER BY id"))
        foreach (r; 0 .. block.rows)
            rows ~= [
            block.columns[0].getString(r), block.columns[1].getString(r),
            block.columns[2].getString(r),
            block.columns[3].getString(r)
    ];
    const string[][] expected = [
        ["1", "Int64", "5", "[1,'x',NULL]"], ["2", "String", "text", "[7,'y']"],
        ["3", "Float64", "2.5", "[]"], ["4", "Date", "2020-01-02", "[]"],
        ["5", "Array(UInt8)", "[1,2]", "[]"], ["6", "Tuple(a UInt8, b String)", "(3,'z')", "[]"],
        ["7", "None", "NULL", "[]"], ["8", "Int64", "9", "[]"], ["9", "None", "NULL", "[]"],
    ];
    enforce(rows == expected, "rows: " ~ rows.to!string);
    enforce(conn.queryRow!Row("SELECT id, v FROM variant_ins WHERE id = 2").v.get!string == "text", "struct read");
}

/// Geometry (newer servers): a Variant of the geo types in a fixed order.
void testGeometry()
{
    auto conn = variantConnection();
    if (conn is null)
        return;
    scope (exit)
        conn.close();
    if (!conn.hasType("Geometry"))
        return;
    conn.exec("CREATE TEMPORARY TABLE geometry_t (id UInt32, g Geometry) ENGINE = Memory");
    conn.exec("INSERT INTO geometry_t VALUES (1, (1.5, 2)), (2, [(0, 0), (1, 1)]), (3, [[(0, 0), (1, 0), (1, 1)]])");
    auto ins = conn.beginInsert("INSERT INTO geometry_t VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(4, GeoPoint(5, 6)); // a Tuple: Point
    ins.addRow(5, [GeoPoint(0, 0), GeoPoint(2, 2)]); // the first Array(Point) alternative: LineString
    ins.finish();
    conn.checkRows("SELECT g AS v, toString(g) AS text, variantType(g) AS kind FROM geometry_t ORDER BY id");
    auto block = conn.firstBlock("SELECT g FROM geometry_t WHERE id = 4");
    enforce(block.column("g").typeName == "Geometry", "type name");
    enforce(readValue!GeoPoint(block.column("g"), 0) == GeoPoint(5, 6), "readValue!GeoPoint");
}
