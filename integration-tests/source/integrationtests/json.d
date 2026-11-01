/// JSON tests against a real server (24.10+ for reading as text; skipped where the type is missing). Tables are
/// session temporary tables.
module integrationtests.json;

import std.conv : to;
import std.exception : enforce;
import std.json : JSONValue, parseJSON;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : hasType, serverOptions;

/// A connection where JSON tables can be created and read, or null if the server doesn't have the type or
/// can't send it as text (before 24.10).
private Connection jsonConnection(bool simpleFormats = true)
{
    auto options = serverOptions();
    options.simpleNativeFormats = simpleFormats;
    auto conn = new Connection(options);
    const v = conn.serverInfo;
    if (!conn.hasType("JSON") || v.versionMajor < 24 || (v.versionMajor == 24 && v.versionMinor < 10))
    {
        conn.close();
        return null;
    }
    conn.exec("SET allow_experimental_json_type = 1"); // needed before 25.3
    return conn;
}

/// Each named column must print as its text column (the server's toString()).
private void checkText(Block block, string[2][] pairs)
{
    foreach (r; 0 .. block.rows)
        foreach (p; pairs)
        {
            auto c = block.column(p[0]);
            const expected = block.column(p[1]).getString(r);
            const got = c.isNull(r) ? "NULL" : c.getString(r);
            enforce(got == expected, p[0] ~ " row " ~ r.to!string ~ ": '" ~ got ~ "', the server says '" ~ expected
                    ~ "'");
        }
}

/// Reading JSON as text: plain, with typed paths, Nullable, inside Array, Tuple and Dynamic.
void testJsonRead()
{
    auto conn = jsonConnection();
    if (conn is null)
        return;
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE json_read (id UInt32, j JSON(max_dynamic_paths=2, `a.b` UInt32, SKIP x), "
            ~ "n Nullable(JSON)) ENGINE = Memory");
    conn.exec(`INSERT INTO json_read VALUES (1, '{"a":{"b":5},"s":"it''s","arr":[1,"x",{"k":2}],"f":0.1}', NULL), `
            ~ `(2, '{"u":18446744073709551615,"neg":-1,"d":"2020-01-02","n":null,"o":{}}', '{"p":1}'), `
            ~ `(3, '{}', '{}'), (4, '{"many":1,"paths":2,"beyond":3,"max":4}', NULL)`);
    auto block = conn.firstBlock("SELECT j, toString(j) AS jt, n, if(isNull(n), 'NULL', toString(n)) AS nt, "
            ~ "[j] AS a, toString(a) AS at, tuple(j, 1) AS t, toString(t) AS tt FROM json_read ORDER BY id");
    enforce(block.rows == 4 && cast(JsonColumn) block.column("j") !is null, "JSON column");
    block.checkText([["j", "jt"], ["n", "nt"], ["a", "at"], ["t", "tt"]]);
    const doc = readValue!JSONValue(block.column("j"), 0);
    enforce(doc["a"]["b"].integer == 5 && doc["s"].str == "it's", "readValue!JSONValue");

    // Many rows over several blocks
    size_t rows;
    foreach (b; conn.query(`SELECT concat('{"k":', toString(number), ',"v":"', toString(number), '"}')::JSON AS j, `
            ~ "toString(j) AS jt FROM numbers(50000)"))
    {
        b.checkText([["j", "jt"]]);
        rows += b.rows;
    }
    enforce(rows == 50_000, "rows: " ~ rows.to!string);

    // JSON values inside Dynamic
    if (conn.hasType("Dynamic"))
    {
        conn.exec("SET allow_experimental_dynamic_type = 1");
        block = conn.firstBlock(`SELECT '{"a":1}'::JSON::Dynamic AS d, toString(d) AS dt`);
        block.checkText([["d", "dt"]]);
        enforce((cast(DynamicColumn) block.column("d")).dynamicTypeName(0) == "JSON", "JSON in Dynamic");
    }
}

/// Inserting JSON from text, JSONValue and structs; invalid JSON is rejected by the server.
void testJsonInsert()
{
    static struct Doc
    {
        uint id;
        JSONValue j;
    }

    auto conn = jsonConnection();
    if (conn is null)
        return;
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE json_ins (id UInt32, j JSON, a Array(JSON)) ENGINE = Memory");
    auto ins = conn.beginInsert("INSERT INTO json_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, `{"b":2,"a":{"x":"it's"}}`, `['{"k":1}', '{}']`);
    ins.addRow(2, parseJSON(`{"n":[1,2,3],"f":1.5}`), [parseJSON(`{"q":true}`)]);
    ins.finish();
    conn.insert("json_ins", [Doc(3, parseJSON(`{"z":null,"y":"v"}`))]);

    string[][] rows;
    foreach (block; conn.query("SELECT toString(j), toString(a) FROM json_ins ORDER BY id"))
        foreach (r; 0 .. block.rows)
            rows ~= [block.columns[0].getString(r), block.columns[1].getString(r)];
    const string[][] expected = [
        [`{"a":{"x":"it's"},"b":2}`, `['{"k":1}','{}']`], [
            `{"f":1.5,"n":[1,2,3]}`, `['{"q":true}']`
        ],
        [`{"y":"v"}`, `[]`],
    ];
    enforce(rows == expected, "rows: " ~ rows.to!string);
    enforce(conn.queryRow!Doc("SELECT id, j FROM json_ins WHERE id = 2").j["n"].array.length == 3, "struct read");

    // Invalid JSON is rejected before it is sent (the server would close the connection)
    bool rejected;
    auto bad = conn.beginInsert("INSERT INTO json_ins (id, j) VALUES");
    try
        bad.addRow(5, "{not json");
    catch (ClientException)
        rejected = true;
    bad.finish();
    enforce(rejected, "invalid JSON must be rejected");
    enforce(conn.queryValue!ulong("SELECT count() FROM json_ins") == 3, "no invalid rows");
}

/// Without the text form (the option off), reading a JSON column fails with a clear error.
void testJsonInternalFormRejected()
{
    auto conn = jsonConnection(false);
    if (conn is null)
        return;
    scope (exit)
        conn.close();
    bool failed;
    try
        conn.firstBlock(`SELECT '{"a":1}'::JSON AS j`);
    catch (ClientException e)
        failed = true;
    enforce(failed, "reading the internal JSON form must throw ClientException");
    enforce(!conn.isOpen, "the connection closes, as the block can't be skipped");
}
