/// Floating-point tests against a real server: Float32/Float64 text and BFloat16. All tables are session temporary tables.
module integrationtests.floats;

import std.conv : to;
import std.exception : enforce;
import std.typecons : Nullable;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer, hasType;

/// Every value of `values` must print as its neighbour column `text` (the server's toString()).
private void checkText(Block block, string values, string text)
{
    auto v = block.column(values);
    auto t = block.column(text);
    foreach (r; 0 .. block.rows)
        enforce(v.getString(r) == t.getString(r), v.typeName ~ " row " ~ r.to!string ~ ": '" ~ v.getString(
                r) ~ "', the server says '" ~ t.getString(r) ~ "'");
}

/// Float32 and Float64 getString must equal the server's toString(): the shortest text that reads back exactly.
void testFloatText()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    // Pseudo-random bit patterns (deterministic), so every exponent range is covered
    size_t rows;
    foreach (block; conn.query("SELECT reinterpretAsFloat64(sipHash64(number)) AS d, toString(d) AS dt, "
            ~ "reinterpretAsFloat32(toUInt32(sipHash64(number) % 4294967296)) AS f, toString(f) AS ft "
            ~ "FROM numbers(20000)"))
    {
        checkText(block, "d", "dt");
        checkText(block, "f", "ft");
        rows += block.rows;
    }
    enforce(rows == 20_000, "rows: " ~ rows.to!string);

    auto block = conn.firstBlock("SELECT arrayJoin([0.1 + 0.2, 1e21, 1e20, 1e-7, 1e-6, -0., 1.5e300, "
            ~ "inf, -inf, nan, toFloat64(9223372036854775807), 123456.789]) AS d, toString(d) AS dt, "
            ~ "toFloat32(d) AS f, toString(f) AS ft");
    checkText(block, "d", "dt");
    checkText(block, "f", "ft");
    enforce(block.column("d").getString(0) == "0.30000000000000004", "0.1 + 0.2");
    block = conn.firstBlock("SELECT CAST([0.1, 9999220736., 1e-10] AS Array(Float32)) AS a, toString(a) AS at");
    checkText(block, "a", "at");
}

/// BFloat16 (newer servers only): bits and text of every value, Nullable and Array.
void testBFloat16Read()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    if (!conn.hasType("BFloat16"))
        return;
    // All 65536 bit patterns: the column keeps the raw bits, and the text matches the server's
    size_t rows;
    foreach (block; conn.query(
            "SELECT reinterpret(toUInt16(number), 'BFloat16') AS b, toString(b) AS bt, "
            ~ "number FROM numbers(65536)"))
    {
        auto b = block.column!BFloat16Column("b");
        auto n = block.column!UInt64Column("number");
        foreach (r; 0 .. block.rows)
            enforce(b.data[r] == n.data[r], "bits of row " ~ r.to!string);
        checkText(block, "b", "bt");
        rows += block.rows;
    }
    enforce(rows == 65_536, "rows: " ~ rows.to!string);

    auto block = conn.firstBlock("SELECT toBFloat16(0.1) AS b, toNullable(toBFloat16(-2.5)) AS n, "
            ~ "CAST(NULL AS Nullable(BFloat16)) AS z, CAST([1.5, nan, -0.] AS Array(BFloat16)) AS a, "
            ~ "toString(a) AS at");
    auto b = block.column!BFloat16Column("b");
    enforce(b.typeName == "BFloat16" && b[0] == 0.099609375f && b.getString(0) == "0.099609375", "toBFloat16(0.1)");
    enforce(block.column("n").getDouble(0) == -2.5 && block.column("z").isNull(0), "Nullable(BFloat16)");
    checkText(block, "a", "at");
    enforce(readValue!float(block.column("b"), 0) == 0.099609375f, "readValue!float");
    enforce(readValue!(float[])(block.column("a"), 0).length == 3, "readValue!(float[])");
}

/// Inserting BFloat16 values: numbers are truncated to 16 bits exactly as the server converts them.
void testBFloat16Insert()
{
    static struct Row
    {
        uint id;
        double src;
        float v;
        float[] a;
    }

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    if (!conn.hasType("BFloat16"))
        return;
    conn.exec("CREATE TEMPORARY TABLE bf16_ins (id UInt32, src Float64, v BFloat16, n Nullable(BFloat16), "
            ~ "a Array(BFloat16)) ENGINE = Memory");
    const double[] values = [
        0.1, 65_504, 1.01171875, 3.14159, -1e10, 1e-40, 3.4e38, 123_456_789, 0, -0.0, double.infinity
    ];
    auto ins = conn.beginInsert("INSERT INTO bf16_ins VALUES");
    scope (failure)
        ins.abort();
    foreach (i, v; values)
        ins.addRow(cast(uint) i, v, v, i % 2 ? Nullable!double(v) : Nullable!double.init, [v, -v]);
    ins.addRow(100, 2.75, "2.75", "-0.5", "[1,2.5]");
    ins.finish();
    conn.insert("bf16_ins", [Row(101, 7, 7.0f, [0.5f])]);

    // The server converts the same Float64 to BFloat16 and must get the same bits
    const mismatches = conn.queryValue!ulong("SELECT count() FROM bf16_ins WHERE id < 100 AND ("
            ~ "reinterpretAsUInt16(v) != reinterpretAsUInt16(toBFloat16(src)) "
            ~ "OR (n IS NOT NULL AND reinterpretAsUInt16(assumeNotNull(n)) != reinterpretAsUInt16(toBFloat16(src))) "
            ~ "OR reinterpretAsUInt16(a[1]) != reinterpretAsUInt16(toBFloat16(src)) "
            ~ "OR reinterpretAsUInt16(a[2]) != reinterpretAsUInt16(toBFloat16(-src)))");
    enforce(mismatches == 0, mismatches.to!string ~ " rows differ from the server's conversion");
    enforce(conn.queryValue!ulong("SELECT count() FROM bf16_ins WHERE n IS NULL") == 6 + 1, "NULLs");
    enforce(conn.queryValue!string(
            "SELECT toString(tuple(v, n, a)) FROM bf16_ins WHERE id = 100") == "(2.75,-0.5,[1,2.5])",
            "text insert");

    const back = conn.queryRow!Row("SELECT id, src, v, a FROM bf16_ins WHERE id = 0");
    enforce(back.v == 0.099609375f && back.a == [0.099609375f, -0.099609375f], "struct round trip: " ~ back.to!string);
    enforce(conn.queryRow!Row("SELECT id, src, v, a FROM bf16_ins WHERE id = 101") == Row(101, 7, 7.0f, [
        0.5f
    ]),
    "conn.insert of structs");
}
