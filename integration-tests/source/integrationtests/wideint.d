/// Int128, UInt128, Int256 and UInt256 tests against a real server. Tables are session temporary tables.
module integrationtests.wideint;

import std.bigint : BigInt;
import std.conv : to;
import std.exception : enforce;
import std.typecons : Nullable;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer;

private enum int128Min = "-170141183460469231731687303715884105728";
private enum uint128Max = "340282366920938463463374607431768211455";
private enum int256Min = "-57896044618658097711785492504343953926634992332820282019728792003956564819968";
private enum uint256Max = "115792089237316195423570985008687907853269984665640564039457584007913129639935";

/// Limits and other values of every type: getString must equal the server's toString().
void testWideIntRead()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto block = conn.firstBlock("SELECT toInt128('" ~ int128Min ~ "') AS a, toString(a), "
            ~ "toUInt128('" ~ uint128Max ~ "') AS b, toString(b), toInt256('" ~ int256Min ~ "') AS c, toString(c), "
            ~ "toUInt256('" ~ uint256Max ~ "') AS d, toString(d), toInt128(-1) AS e, toString(e), "
            ~ "toUInt256(0) AS f, toString(f), CAST(NULL AS Nullable(Int256)) AS g, 'NULL', "
            ~ "[toInt128(1), toInt128(-2)] AS h, toString(h)");
    for (size_t i = 0; i < block.columns.length; i += 2)
    {
        auto c = block.columns[i];
        const ours = c.isNull(0) ? "NULL" : c.getString(0);
        const expected = block.columns[i + 1].getString(0);
        enforce(ours == expected, c.name ~ " (" ~ c.typeName ~ "): '" ~ ours ~ "', the server says '" ~ expected ~ "'");
    }
    enforce(block.column!Int128Column("a").data == [Int128.min], "Int128.min");
    enforce(readValue!BigInt(block.column("d"), 0) == BigInt(uint256Max), "UInt256 as BigInt");
}

/// Many rows over several blocks, with values beyond 64 bits.
void testWideIntManyRows()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    const factor = BigInt("1000000000000000000000000000000"); // 10^30
    size_t rows;
    foreach (block; conn.query("SELECT number, toInt256(number) * toInt256('1000000000000000000000000000000') "
            ~ "* if(number % 2 = 0, 1, -1) AS v FROM numbers(100000)", ["max_block_size": "8192"]))
    {
        auto numbers = block.column!UInt64Column("number").data;
        auto values = block.column!Int256Column("v").data;
        foreach (row; 0 .. block.rows)
        {
            const n = numbers[row];
            const expected = BigInt(n) * factor * (n % 2 == 0 ? 1 : -1);
            enforce(values[row].toBigInt() == expected, "row " ~ n.to!string);
        }
        rows += block.rows;
    }
    enforce(rows == 100_000, "rows: " ~ rows.to!string);
}

/// Inserting wide integers from WideInt values, BigInt, text and built-in integers; literals and parameters.
void testWideIntInsert()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE wide_ins (id UInt32, a Int128, b UInt128, c Int256, d UInt256, "
            ~ "n Nullable(Int256), arr Array(UInt128)) ENGINE = Memory");
    auto ins = conn.beginInsert("INSERT INTO wide_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, Int128.min, UInt128.max, Int256.min, UInt256.max, Int256.max, [
        UInt128(0), UInt128.max
    ]);
    ins.addRow(2, BigInt("-12345678901234567890123"), -0L, "99999999999999999999999999999", 42, null,
            cast(UInt128[]) null);
    ins.finish();

    auto block = conn.firstBlock("SELECT toString(a), toString(b), toString(c), toString(d), toString(n), "
            ~ "toString(arr) FROM wide_ins ORDER BY id");
    string[] row(size_t r)
    {
        string[] values;
        foreach (c; block.columns)
            values ~= c.isNull(r) ? "NULL" : c.getString(r);
        return values;
    }

    enforce(row(0) == [
        int128Min, uint128Max, int256Min, uint256Max, Int256.max.toString(),
        "[0," ~ uint128Max ~ "]"
    ], "row 1: " ~ row(0).to!string);
    enforce(row(1) == [
        "-12345678901234567890123", "0", "99999999999999999999999999999", "42", "NULL", "[]"
    ],
    "row 2: " ~ row(1).to!string);

    // Struct mapping both ways
    static struct Row
    {
        uint id;
        Int128 a;
        UInt128 b;
        BigInt c;
        UInt256 d;
        Nullable!Int256 n;
        UInt128[] arr;
    }

    conn.insert("wide_ins", [
        Row(3, Int128(-3), UInt128(3), BigInt(-3), UInt256(3), Nullable!Int256.init, [UInt128(3)])
    ]);
    const back = conn.queryRow!Row("SELECT * FROM wide_ins WHERE id = 3");
    enforce(back.a == Int128(-3) && back.c == BigInt(-3) && back.n.isNull && back.arr == [
        UInt128(3)
    ],
    "struct round trip");

    // formatLiteral and query parameters keep all digits
    const viaLiteral = conn.queryValue!Int256("SELECT " ~ formatLiteral(Int256.min));
    enforce(viaLiteral == Int256.min, "literal: " ~ viaLiteral.toString());
    const viaParameter = conn.queryValue!UInt256("SELECT {v:UInt256}", null, ["v": uint256Max]);
    enforce(viaParameter == UInt256.max, "parameter: " ~ viaParameter.toString());
}
