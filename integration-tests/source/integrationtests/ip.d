/// IPv4 and IPv6 tests against a real server. All tables are session temporary tables.
module integrationtests.ip;

import std.conv : to;
import std.exception : enforce;
import std.typecons : Nullable;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer;

/// Typical and edge-case addresses: getString must equal the server's toString().
void testIpRead()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    string sql = "SELECT ";
    size_t n;
    void add(string function_, string address)
    {
        const name = "c" ~ n.to!string;
        n++;
        sql ~= function_ ~ "('" ~ address ~ "') AS " ~ name ~ ", toString(" ~ name ~ "), ";
    }

    foreach (address; ["0.0.0.0", "255.255.255.255", "1.2.3.4", "10.0.0.1"])
        add("toIPv4", address);
    foreach (address; [
        "::", "::1", "2001:db8::7", "1.2.3.4", "2001:0db8:0000:0000:0001:0000:0000:0001",
        "fe80::1:0:0:1",
        "::ffff:0:0", "::1.2.3.4", "1:2:3:4:5:6:7:8", "1::", "1:0:0:2:0:0:0:3", "abcd:ef01::"
    ])
        add("toIPv6", address);
    sql ~= "CAST(NULL AS Nullable(IPv6)) AS cn, 'NULL', [toIPv4('1.2.3.4'), toIPv4('5.6.7.8')] AS ca, toString(ca), "
        ~ "[toIPv6('::1')] AS cb, toString(cb)";
    auto block = conn.firstBlock(sql);
    for (size_t i = 0; i < block.columns.length; i += 2)
    {
        auto c = block.columns[i];
        const ours = c.isNull(0) ? "NULL" : c.getString(0);
        const expected = block.columns[i + 1].getString(0);
        enforce(ours == expected, c.name ~ " (" ~ c.typeName ~ "): '" ~ ours ~ "', the server says '" ~ expected ~ "'");
    }
    enforce(block.column!IPv4Column("c2")[0] == IPv4(0x0102_0304), "IPv4 value");
    enforce(block.column!IPv6Column("c5").getBytes(0) == [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    ], "IPv6 bytes");
}

/// Many addresses with varied zero groups: getString against toString() row by row.
void testIpManyRows()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    size_t rows;
    foreach (block; conn.query("SELECT toIPv4(toUInt32(number * 2654435761 % 4294967296)) AS a, toString(a), "
            ~ "toIPv6(arrayStringConcat(arrayMap(x -> hex(toUInt16(x)), [number % 3, 0, number % 2, 0, 0, "
            ~ "if(number % 7 = 0, 65535, number % 5), number % 4, number % 65536]), ':')) AS b, toString(b) "
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

/// Inserting addresses from IPv4/IPv6 values, text and numbers; struct mapping, literals, parameters.
void testIpInsert()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE ip_ins (id UInt32, a IPv4, b IPv6, n Nullable(IPv6), arr Array(IPv4)) "
            ~ "ENGINE = Memory");
    auto ins = conn.beginInsert("INSERT INTO ip_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, IPv4.fromString("192.168.0.1"), IPv6.fromString("2001:db8::7"), null,
            [IPv4.fromString("1.2.3.4"), IPv4(0)]);
    ins.addRow(2, 0x7f00_0001UL, "10.0.0.1", IPv4.fromString("8.8.8.8"), cast(IPv4[]) null);
    ins.finish();

    auto block = conn.firstBlock("SELECT toString(a), toString(b), toString(n), toString(arr) FROM ip_ins ORDER BY id");
    string[] row(size_t r)
    {
        string[] values;
        foreach (c; block.columns)
            values ~= c.isNull(r) ? "NULL" : c.getString(r);
        return values;
    }

    enforce(row(0) == ["192.168.0.1", "2001:db8::7", "NULL", "['1.2.3.4','0.0.0.0']"], "row 1: " ~ row(0).to!string);
    enforce(row(1) == ["127.0.0.1", "::ffff:10.0.0.1", "::ffff:8.8.8.8", "[]"], "row 2: " ~ row(1).to!string);

    // Struct mapping both ways
    static struct Row
    {
        uint id;
        IPv4 a;
        string b;
        Nullable!IPv6 n;
        IPv4[] arr;
    }

    conn.insert("ip_ins", [
        Row(3, IPv4(1), "::2", Nullable!IPv6(IPv6.fromString("fe80::1")), [IPv4(2)])
    ]);
    const back = conn.queryRow!Row("SELECT * FROM ip_ins WHERE id = 3");
    enforce(back.a == IPv4(1) && back.b == "::2" && back.n.get.toString() == "fe80::1" && back.arr == [
        IPv4(2)
    ],
    "struct round trip: " ~ back.to!string);

    enforce(conn.queryValue!IPv6("SELECT " ~ formatLiteral(
            IPv6.fromString("::ffff:1.2.3.4")))
            == IPv6.mapped(IPv4.fromString("1.2.3.4")), "literal");
    enforce(conn.queryValue!IPv4("SELECT {v:IPv4}", null, ["v": "9.9.9.9"]) == IPv4.fromString("9.9.9.9"), "parameter");
}
