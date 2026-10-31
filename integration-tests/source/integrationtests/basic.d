/// Basic protocol tests against a real server: handshake, queries, errors,
/// connection state rules and the column types supported so far.
module integrationtests.basic;

import std.exception : assertThrown, collectException, enforce;

import clickhoused;
import integrationtests.server : connectToServer;

/// Runs a query, returns its first data block and frees the connection.
Block firstBlock(Connection conn, string sql, const string[string] settings = null,
        const string[string] parameters = null)
{
    auto result = conn.query(sql, settings, parameters);
    scope (exit)
        result.close();
    enforce(!result.empty, "no data returned by: " ~ sql);
    return result.front;
}

/// Handshake fills in server information; ping works.
void testHandshakeAndPing()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    with (conn.serverInfo)
    {
        enforce(name.length > 0, "empty server name");
        enforce(versionMajor >= 23, "unexpected server version");
        enforce(timezone.length > 0, "empty server timezone");
    }
    enforce(conn.revision > 0 && conn.revision <= 54_460, "unexpected effective revision");
    conn.ping();
    conn.ping();
    enforce(conn.isOpen && !conn.isBusy);
}

/// The simplest query.
void testSelectOne()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto result = conn.query("SELECT 1 AS one");
    enforce(!result.empty, "no data");
    auto block = result.front;
    enforce(block.rows == 1);
    enforce(block.column!UInt8Column("one").data == [1]);
    result.popFront();
    enforce(result.empty, "more than one block");
    enforce(result.header.columns[0].typeName == "UInt8");
    enforce(!conn.isBusy);
}

/// A result large enough to arrive in many blocks.
void testManyBlocks()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    enum ulong n = 1_000_000;
    ulong sum, rows;
    size_t blocks;
    auto result = conn.query("SELECT number FROM system.numbers LIMIT 1000000");
    foreach (block; result)
    {
        blocks++;
        rows += block.rows;
        foreach (v; block.column!UInt64Column("number").data)
            sum += v;
    }
    enforce(rows == n, "wrong row count");
    enforce(sum == n * (n - 1) / 2, "wrong sum");
    enforce(blocks > 1, "expected several blocks");
    enforce(result.stats.progress.readRows >= n, "progress not accumulated");
}

/// Every column type supported so far, including extreme values.
void testBasicTypes()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto result = conn.query(`SELECT
            toUInt8(255) AS u8, toUInt16(65535) AS u16, toUInt32(4294967295) AS u32,
            toUInt64(18446744073709551615) AS u64,
            toInt8(-128) AS i8, toInt16(-32768) AS i16, toInt32(-2147483648) AS i32,
            toInt64(-9223372036854775808) AS i64,
            toFloat32(1.5) AS f32, toFloat64(-2.25) AS f64,
            true AS b, 'héllo' AS s, '' AS empty, toFixedString('ab', 4) AS fs`);
    auto block = result.front;
    enforce(block.column!UInt8Column("u8").data == [255]);
    enforce(block.column!UInt16Column("u16").data == [65_535]);
    enforce(block.column!UInt32Column("u32").data == [uint.max]);
    enforce(block.column!UInt64Column("u64").data == [ulong.max]);
    enforce(block.column!Int8Column("i8").data == [byte.min]);
    enforce(block.column!Int16Column("i16").data == [short.min]);
    enforce(block.column!Int32Column("i32").data == [int.min]);
    enforce(block.column!Int64Column("i64").data == [long.min]);
    enforce(block.column!Float32Column("f32").data == [1.5f]);
    enforce(block.column!Float64Column("f64").data == [-2.25]);
    enforce(block.column!BoolColumn("b").data == [true]);
    enforce(block.column!StringColumn("s").data == ["héllo"]);
    enforce(block.column!StringColumn("empty").data == [""]);
    auto fs = block.column!FixedStringColumn("fs");
    enforce(fs.width == 4 && fs[0] == cast(const(ubyte)[]) "ab\0\0" && fs.asString(0) == "ab");
    result.close();
}

/// DDL and INSERT ... SELECT through `exec`, in a session temporary table.
void testDdlAndInsertSelect()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE t (id UInt32, name String) ENGINE = Memory");
    const stats = conn.exec("INSERT INTO t SELECT number, toString(number) FROM numbers(10)");
    enforce(stats.progress.writtenRows == 10, "written rows not reported");
    auto block = conn.firstBlock("SELECT count() AS c, sum(id) AS s FROM t");
    enforce(block.column!UInt64Column("c").data == [10]);
    enforce(block.column!UInt64Column("s").data == [45]);
    conn.exec("DROP TEMPORARY TABLE t");
}

/// A server error is reported as `ServerException` and leaves the connection usable.
void testServerError()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto e = collectException!ServerException(conn.exec("SELECT * FROM no_such_table_clickhoused_test"));
    enforce(e !is null, "no exception");
    enforce(e.code == 60, "expected UNKNOWN_TABLE (60)");
    e = collectException!ServerException(conn.exec("SELEC 1"));
    enforce(e !is null && e.code == 62, "expected SYNTAX_ERROR (62)");
    enforce(conn.isOpen && !conn.isBusy);
    enforce(conn.firstBlock("SELECT 2 AS x").column!UInt8Column("x").data == [2]);
}

/// A column type this version cannot decode closes the connection with a clear error.
void testUnsupportedType()
{
    import std.algorithm.searching : canFind;

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto e = collectException!ClientException(conn.exec("SELECT INTERVAL 1 DAY AS i"));
    enforce(e !is null, "no exception");
    enforce(e.msg.canFind("IntervalDay"), "type name missing from message: " ~ e.msg);
    enforce(!conn.isOpen, "connection should be closed");
    assertThrown!ClientException(conn.ping());
}

/// A second query while the first result is unread is rejected.
void testBusyConnection()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto result = conn.query("SELECT number FROM numbers(100000)");
    enforce(conn.isBusy);
    assertThrown!ClientException(conn.query("SELECT 1"));
    assertThrown!ClientException(conn.ping());
    result.close();
    enforce(!conn.isBusy);
    conn.ping();
}

/// LowCardinality columns arrive dictionary-encoded and are usable as their plain type.
void testLowCardinality()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    auto block = conn.firstBlock("SELECT toLowCardinality('abc') AS lc");
    enforce(block.columns[0].typeName == "LowCardinality(String)", "got " ~ block.columns[0].typeName);
    enforce(block.column!StringColumn("lc").data == ["abc"]);
}

/// Connection-level and per-query settings, and query parameters.
void testSettingsAndParameters()
{
    import integrationtests.server : serverOptions;

    auto options = serverOptions();
    options.settings["max_threads"] = "3";
    auto conn = new Connection(options);
    scope (exit)
        conn.close();

    auto block = conn.firstBlock("SELECT toUInt64(getSetting('max_threads')) AS v");
    enforce(block.column!UInt64Column("v").data == [3], "connection setting not applied");
    block = conn.firstBlock("SELECT toUInt64(getSetting('max_threads')) AS v", ["max_threads": "5"]);
    enforce(block.column!UInt64Column("v").data == [5], "query setting not applied");

    block = conn.firstBlock("SELECT {a:UInt32} + 1 AS x, {s:String} AS s", null, [
        "a": "41",
        "s": "it's"
    ]);
    enforce(block.column!UInt64Column("x").data == [42], "numeric parameter");
    enforce(block.column!StringColumn("s").data == ["it's"], "string parameter");

    // A bad parameter is a query error: the connection stays usable
    auto e = collectException!ServerException(conn.exec("SELECT {a:UInt32}", null, ["a": "x"]));
    enforce(e !is null && e.code == 457, "expected BAD_QUERY_PARAMETER (457)");
    conn.ping();

    // Unknown settings are rejected, not silently ignored. The server closes
    // the connection after this error, so use a separate one.
    auto other = new Connection(options);
    scope (exit)
        other.close();
    e = collectException!ServerException(other.exec("SELECT 1", ["no_such_setting_xyz": "1"]));
    enforce(e !is null && e.code == 115, "expected UNKNOWN_SETTING (115)");
}
