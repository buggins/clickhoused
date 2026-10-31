/// Decimal(P, S) tests against a real server. All tables are session temporary tables.
module integrationtests.decimal;

import std.conv : to;
import std.exception : enforce;
import std.typecons : Nullable;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer;

/// Every storage width, limits and scales: getString must equal the server's toString().
void testDecimalRead()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto block = conn.firstBlock(`SELECT
            toDecimal32('-9999999.99', 2) AS d1, toString(d1),
            toDecimal32('0.000000001', 9) AS d2, toString(d2),
            CAST('-999999999999999999' AS Decimal(18, 0)) AS d3, toString(d3),
            toDecimal64('123.4500', 4) AS d4, toString(d4),
            CAST('-99999999999999999999.999999999999999999' AS Decimal(38, 18)) AS d5, toString(d5),
            toDecimal128('1.5', 30) AS d6, toString(d6),
            CAST('-1234567890123456789012345678901234567890.123456789012345678901234567890123456'
                AS Decimal(76, 36)) AS d7, toString(d7),
            toDecimal256('0', 76) AS d8, toString(d8),
            CAST(NULL AS Nullable(Decimal(9, 2))) AS d9, 'NULL',
            [toDecimal32('1.5', 2), toDecimal32('-2', 2)] AS d10, toString(d10)`);
    for (size_t i = 0; i < block.columns.length; i += 2)
    {
        auto c = block.columns[i];
        const ours = c.isNull(0) ? "NULL" : c.getString(0);
        const expected = block.columns[i + 1].getString(0);
        enforce(ours == expected, c.name ~ " (" ~ c.typeName ~ "): '" ~ ours ~ "', the server says '" ~ expected ~ "'");
    }
    enforce(block.column!Decimal32Column("d1")[0] == Decimal.fromString("-9999999.99"), "Decimal value");
    enforce(readValue!Decimal(block.column("d7"), 0).scale == 36, "scale of the value");
}

/// Many rows over several blocks: getString against the server's toString() in every row.
void testDecimalManyRows()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    size_t rows;
    foreach (block; conn.query("SELECT toDecimal64(number, 3) / 7 - 5000 AS a, toString(a), "
            ~ "toDecimal128(number, 20) * toDecimal128('-1.000000000000000001', 18) AS b, toString(b) "
            ~ "FROM numbers(100000)", ["max_block_size": "8192"]))
    {
        foreach (row; 0 .. block.rows)
            foreach (k; [0, 2])
                enforce(block.columns[k].getString(row) == block.columns[k + 1].getString(row),
                        block.columns[k].typeName ~ ": '" ~ block.columns[k].getString(
                        row) ~ "' / '"
                        ~ block.columns[k + 1].getString(row) ~ "'");
        rows += block.rows;
    }
    enforce(rows == 100_000, "rows: " ~ rows.to!string);
}

/// Inserting Decimal values, text (truncated like the server does), doubles and integers.
void testDecimalInsert()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE dec_ins (id UInt32, a Decimal(9, 2), b Decimal(18, 6), c Decimal(38, 10), "
            ~ "d Decimal(76, 30), n Nullable(Decimal(20, 3)), arr Array(Decimal(9, 2))) ENGINE = Memory");
    auto ins = conn.beginInsert("INSERT INTO dec_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, Decimal.fromString("-9999999.99"), "123.4567899", 0.1, Decimal.fromString("-1.5"), null,
            [Decimal.fromString("1.5"), Decimal.fromString("-0.01")]);
    ins.addRow(2, 42, -1, "-12345678901234567890.0123456789", "1" ~ "0".replicate(45) ~ ".5", "7.0005",
            cast(Decimal[]) null);
    ins.finish();

    auto block = conn.firstBlock("SELECT toString(a), toString(b), toString(c), toString(d), toString(n), "
            ~ "toString(arr) FROM dec_ins ORDER BY id");
    string[] row(size_t r)
    {
        string[] values;
        foreach (c; block.columns)
            values ~= c.isNull(r) ? "NULL" : c.getString(r);
        return values;
    }

    enforce(row(0) == ["-9999999.99", "123.456789", "0.1", "-1.5", "NULL", "[1.5,-0.01]"], "row 1: " ~ row(0)
            .to!string);
    enforce(row(1) == [
        "42", "-1", "-12345678901234567890.0123456789", "1" ~ "0".replicate(45) ~ ".5", "7", "[]"
    ],
    "row 2: " ~ row(1).to!string);

    // Struct mapping both ways
    static struct Row
    {
        uint id;
        Decimal a;
        double b;
        string c;
        Decimal d;
        Nullable!Decimal n;
        Decimal[] arr;
    }

    conn.insert("dec_ins", [
        Row(3, Decimal.fromString("0.05"), 2.5, "3.3", Decimal.fromString("4"),
                Nullable!Decimal(Decimal.fromString("-0.001")), [Decimal.fromString("9.99")])
    ]);
    const back = conn.queryRow!Row("SELECT * FROM dec_ins WHERE id = 3");
    enforce(back.a == Decimal.fromString("0.05") && back.b == 2.5 && back.c == "3.3", "struct round trip: " ~ back
            .to!string);
    enforce(back.n.get.toString() == "-0.001" && back.arr == [Decimal.fromString("9.99")],
            "struct round trip: " ~ back.to!string);

    // formatLiteral and query parameters keep all digits
    const big = Decimal.fromString("-1234567890123456789012345678901234567890.12345678901234567890123456789012345");
    enforce(conn.queryValue!Decimal("SELECT " ~ formatLiteral(big)) == big, "literal");
    enforce(conn.queryValue!Decimal("SELECT {v:Decimal(38, 4)}", null, ["v": "-1.2345"]) == Decimal.fromString(
            "-1.2345"),
            "parameter");
}

private string replicate(string s, size_t n)
{
    string r;
    foreach (i; 0 .. n)
        r ~= s;
    return r;
}
