/// Dynamic tests against a real server (24.5+; skipped where the type is missing). Tables are session temporary tables.
module integrationtests.dynamic;

import std.conv : to;
import std.datetime.date : Date;
import std.datetime.systime : SysTime;
import std.datetime.timezone : UTC;
import std.exception : enforce;
import std.typecons : Nullable;
import std.uuid : UUID;
import std.variant : Variant;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer, hasType, serverOptions;

/// A connection where Dynamic tables can be created (with or without the flattened form), or null if the
/// server doesn't have the type.
private Connection dynamicConnection(bool simpleFormats = true)
{
    auto options = serverOptions();
    options.simpleNativeFormats = simpleFormats;
    auto conn = new Connection(options);
    if (!conn.hasType("Dynamic"))
    {
        conn.close();
        return null;
    }
    conn.exec("SET allow_experimental_dynamic_type = 1"); // needed before 25.3
    return conn;
}

/// Whether the server sends the flattened form (25.6+).
private bool flattenedForm(Connection conn)
{
    const v = conn.serverInfo;
    return v.versionMajor > 25 || (v.versionMajor == 25 && v.versionMinor >= 6);
}

/// Every non-NULL cell of column `d` must print as column `text` (toString()) and have the type in `kind`
/// (dynamicType()); returns the number of rows.
private size_t checkRows(Connection conn, string sql)
{
    size_t rows;
    foreach (block; conn.query(sql))
    {
        auto d = cast(DynamicColumn) block.column("d");
        enforce(d !is null, "not a DynamicColumn: " ~ block.column("d").typeName);
        auto text = block.column("text");
        auto kind = block.column("kind");
        foreach (r; 0 .. block.rows)
        {
            const gotKind = d.isNull(r) ? "None" : d.dynamicTypeName(r);
            enforce(gotKind == kind.getString(r), "row " ~ r.to!string ~ ": type " ~ gotKind ~ ", the server says "
                    ~ kind.getString(r));
            if (!d.isNull(r))
                enforce(d.getString(r) == text.getString(r), "row " ~ r.to!string ~ ": '" ~ d.getString(
                        r)
                        ~ "', the server says '" ~ text.getString(r) ~ "'");
        }
        rows += block.rows;
    }
    return rows;
}

private enum valuesSql = "INSERT INTO dyn_read VALUES (1, 1), (2, 18446744073709551615), (3, 2.5), (4, 'ab'), "
    ~ "(5, true), (6, '2020-01-02'), (7, '2020-01-02 03:04:05.123'), (8, [1, 2]), (9, (1, 'x')), "
    ~ "(10, {'k': 1}), (11, NULL), (12, toDecimal64(-1.25, 2)), (13, toUUID('00112233-4455-6677-8899-aabbccddeeff')), "
    ~ "(14, toIPv4('1.2.3.4')), (15, toLowCardinality('lc')), (16, [[1], []]::Array(Array(Int8)))";

/// Reading Dynamic values of many kinds, in the form the connection asks for, and inside Array, Tuple and Map.
void testDynamicRead()
{
    auto conn = dynamicConnection();
    if (conn is null)
        return;
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE dyn_read (id UInt32, d Dynamic) ENGINE = Memory");
    conn.exec(valuesSql);
    enforce(conn.checkRows("SELECT d, toString(d) AS text, dynamicType(d) AS kind FROM dyn_read ORDER BY id") == 16,
            "rows");

    // Many rows: each block has its own type list
    conn.exec("INSERT INTO dyn_read SELECT 100 + number, multiIf(number % 4 = 0, number::Dynamic, number % 4 = 1, "
            ~ "toString(number)::Dynamic, number % 4 = 2, NULL, [number]::Dynamic) FROM numbers(30000)");
    enforce(conn.checkRows("SELECT d, toString(d) AS text, dynamicType(d) AS kind FROM dyn_read ORDER BY id")
            == 30_016, "rows");

    auto block = conn.firstBlock("SELECT [d, NULL] AS a, toString(a) AS at, tuple(d, 1) AS t, toString(t) AS tt, "
            ~ "map('k', d) AS m, toString(m) AS mt FROM dyn_read WHERE id IN (1, 4, 8) ORDER BY id");
    foreach (r; 0 .. block.rows)
        foreach (pair; [["a", "at"], ["t", "tt"], ["m", "mt"]])
            enforce(block.column(pair[0]).getString(r) == block.column(pair[1]).getString(r), pair[0] ~ ": '"
                    ~ block.column(pair[0])
                        .getString(r) ~ "', the server says '"
                    ~ block.column(pair[1]).getString(r) ~ "'");

    block = conn.firstBlock("SELECT d FROM dyn_read WHERE id IN (1, 8, 11) ORDER BY id");
    auto d = block.column("d");
    enforce(d.getLong(0) == 1 && readValue!Variant(d, 0).get!long == 1, "Int64");
    enforce(readValue!(long[])(d, 1) == [1, 2], "Array(Int64) as long[]");
    enforce(d.isNull(2) && !readValue!Variant(d, 2).hasValue, "NULL");
}

/// The V1 form (servers before 25.6, or the option off): values beyond max_types are binary-encoded; reading
/// them throws, the rest of the stream stays readable, and the encoded values can be copied to another table.
void testDynamicSharedVariant()
{
    auto conn = dynamicConnection(false);
    if (conn is null)
        return;
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE dyn_shared (id UInt32, d Dynamic(max_types=2)) ENGINE = Memory");
    conn.exec("INSERT INTO dyn_shared VALUES (1, 1), (2, 'ab'), (3, NULL), (4, 2.5), (5, '2020-01-02'), (6, [1, 2])");
    auto block = conn.firstBlock("SELECT id, d FROM dyn_shared ORDER BY id");
    auto d = cast(DynamicColumn) block.column("d");
    enforce(d.getString(0) == "1" && d.getString(1) == "ab" && d.isNull(2), "decodable values");
    foreach (r; 3 .. 6)
    {
        enforce(d.dynamicTypeName(r) == DynamicColumn.sharedVariantName, "SharedVariant row " ~ r.to!string);
        bool failed;
        try
            d.getString(r);
        catch (ClientException)
            failed = true;
        enforce(failed, "reading a binary-encoded value must throw");
    }
    enforce(conn.queryValue!ulong("SELECT count() FROM dyn_shared") == 6, "the connection is still usable");

    // Copy the block as it is (the encoded values included) into another table
    conn.exec("CREATE TEMPORARY TABLE dyn_copy (id UInt32, d Dynamic(max_types=2)) ENGINE = Memory");
    conn.insert("dyn_copy", block);
    const copied = conn.queryValue!string("SELECT arrayStringConcat(groupArray(if(isNull(d), 'NULL', toString(d))), "
            ~ "'|') FROM (SELECT d FROM dyn_copy ORDER BY id)");
    enforce(copied == "1|ab|NULL|2.5|2020-01-02|[1,2]", "copied: " ~ copied);
}

/// Inserting Dynamic values: types inferred from D values, explicit types, std.variant.Variant, structs.
void testDynamicInsert()
{
    static struct Pair
    {
        ubyte a;
        string b;
    }

    static struct Row
    {
        uint id;
        Variant d;
    }

    auto conn = dynamicConnection();
    if (conn is null)
        return;
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE dyn_ins (id UInt32, d Dynamic) ENGINE = Memory");
    auto ins = conn.beginInsert("INSERT INTO dyn_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, 5);
    ins.addRow(2, "text");
    ins.addRow(3, 2.5);
    ins.addRow(4, true);
    ins.addRow(5, Date(2020, 1, 2));
    ins.addRow(6, SysTime.fromUnixTime(1_600_000_000, UTC()));
    ins.addRow(7, UUID("00112233-4455-6677-8899-aabbccddeeff"));
    ins.addRow(8, [1L, 2]);
    ins.addRow(9, Pair(3, "x"));
    ins.addRow(10, ["k": 1.5]);
    ins.addRow(11, Decimal.fromString("-1.25"));
    ins.addRow(12, null);
    ins.addRow(13, ulong.max);
    ins.finish();
    conn.insert("dyn_ins", [Row(14, Variant("v")), Row(15, Variant.init), Row(16, Variant(7L))]);

    string[][] rows;
    foreach (block; conn.query(
            "SELECT id, dynamicType(d), if(isNull(d), 'NULL', toString(d)) FROM dyn_ins "
            ~ "ORDER BY id"))
        foreach (r; 0 .. block.rows)
            rows ~= [
            block.columns[0].getString(r), block.columns[1].getString(r),
            block.columns[2].getString(r)
    ];
    const string[][] expected = [
        ["1", "Int64", "5"], ["2", "String", "text"], ["3", "Float64", "2.5"], ["4", "Bool", "true"],
        ["5", "Date", "2020-01-02"], ["6", "DateTime", rows[5][2]],
        ["7", "UUID", "00112233-4455-6677-8899-aabbccddeeff"],
        ["8", "Array(Int64)", "[1,2]"], ["9", "Tuple(a UInt64, b String)", "(3,'x')"],
        ["10", "Map(String, Float64)", "{'k':1.5}"], ["11", "Decimal(9, 2)", "-1.25"],
        ["12", "None", "NULL"],
        ["13", "UInt64", "18446744073709551615"], ["14", "String", "v"], ["15", "None", "NULL"],
        ["16", "Int64", "7"],
    ];
    enforce(rows == expected, "rows: " ~ rows.to!string);
    enforce(conn.queryValue!long(
            "SELECT toUnixTimestamp(assumeNotNull(d.DateTime)) FROM dyn_ins WHERE id = 6")
            == 1_600_000_000, "DateTime instant");
    enforce(conn.queryRow!Row("SELECT id, d FROM dyn_ins WHERE id = 8").d.get!(Variant[]).length == 2, "struct read");

    // More types than max_types: the server keeps the extra ones binary-encoded; the flattened form reads them
    conn.exec("CREATE TEMPORARY TABLE dyn_small (id UInt32, d Dynamic(max_types=1)) ENGINE = Memory");
    auto small = conn.beginInsert("INSERT INTO dyn_small VALUES");
    scope (failure)
        small.abort();
    small.addRow(1, 1);
    small.addRow(2, "a");
    small.addRow(3, 2.5);
    small.finish();
    if (conn.flattenedForm)
    {
        auto block = conn.firstBlock("SELECT d FROM dyn_small ORDER BY id");
        enforce(block.column("d").getString(1) == "a" && block.column("d").getString(2) == "2.5",
                "values beyond max_types");
    }
    enforce(conn.queryValue!string("SELECT arrayStringConcat(groupArray(dynamicType(d)), ',') FROM "
            ~ "(SELECT d FROM dyn_small ORDER BY id)") == "Int64,String,Float64", "types beyond max_types");
}
