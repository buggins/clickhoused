/// Geo type tests against a real server. All tables are session temporary tables.
module integrationtests.geo;

import std.conv : to;
import std.exception : enforce;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : connectToServer;

/// Whether the server knows the data type `name` (LineString is newer than 23.8).
private bool hasType(Connection conn, string name)
{
    return conn.queryValue!ulong("SELECT count() FROM system.data_type_families WHERE name = {n:String}", null, [
        "n": name
    ]) > 0;
}

/// Every geo type: getString must equal the server's toString(), and the column keeps the geo type name.
void testGeoRead()
{
    auto conn = connectToServer();
    scope (exit)
        conn.close();
    string[2][] cases = [
        ["Point", "(1.5, -2.0)"], ["Ring", "[(0., 0.), (1., 0.), (1., 1.)]"],
        ["Polygon", "[[(0., 0.), (1., 0.), (1., 1.)], [(0.25, 0.25)]]"],
        ["MultiPolygon", "[[[(0., 0.), (1., 0.)]], []]"],
    ];
    if (conn.hasType("LineString"))
        cases ~= [
        ["LineString", "[(0., 0.), (1., 1.)]"], ["MultiLineString", "[[(0., 0.), (1., 1.)], []]"]
    ];
    string sql = "SELECT ";
    foreach (i, c; cases)
        sql ~= (i ? ", " : "") ~ "CAST(" ~ c[1] ~ " AS " ~ c[0] ~ ") AS c" ~ i.to!string ~ ", toString(c" ~ i
            .to!string ~ ")";
    auto block = conn.firstBlock(sql);
    foreach (i, c; cases)
    {
        auto column = block.columns[2 * i];
        enforce(column.typeName == c[0], "type name: " ~ column.typeName);
        const expected = block.columns[2 * i + 1].getString(0);
        enforce(column.getString(0) == expected, c[0] ~ ": '" ~ column.getString(
                0) ~ "', the server says '" ~ expected ~ "'");
    }
    enforce(readValue!GeoPoint(block.column("c0"), 0) == GeoPoint(1.5, -2), "GeoPoint");
    enforce(readValue!(GeoPoint[][])(block.column("c2"), 0).length == 2, "Polygon as GeoPoint[][]");
}

/// Inserting geo values from GeoPoint arrays and text; struct mapping and literals.
void testGeoInsert()
{
    static struct Shape
    {
        uint id;
        GeoPoint center;
        GeoPoint[] ring;
        GeoPoint[][] area;
        GeoPoint[][][] areas;
    }

    auto conn = connectToServer();
    scope (exit)
        conn.close();
    conn.exec("CREATE TEMPORARY TABLE geo_ins (id UInt32, center Point, ring Ring, area Polygon, areas MultiPolygon) "
            ~ "ENGINE = Memory");
    const square = [GeoPoint(0, 0), GeoPoint(2, 0), GeoPoint(2, 2), GeoPoint(0, 2)];
    auto ins = conn.beginInsert("INSERT INTO geo_ins VALUES");
    scope (failure)
        ins.abort();
    ins.addRow(1, GeoPoint(1, 1), square, [square, [GeoPoint(0.5, 0.5)]], [
        [square], [[GeoPoint(5, 5)]]
    ]);
    ins.addRow(2, "(-1.5, 3)", "[]", "[]", "[]");
    ins.finish();
    conn.insert("geo_ins", [Shape(3, GeoPoint(0.25, -0.75), null, null, null)]);

    string[][] rows;
    foreach (block; conn.query(
            "SELECT toString(center), toString(ring), toString(area), toString(areas) FROM geo_ins "
            ~ "ORDER BY id"))
        foreach (r; 0 .. block.rows)
            rows ~= [
            block.columns[0].getString(r), block.columns[1].getString(r),
            block.columns[2].getString(r),
            block.columns[3].getString(r)
    ];
    enum sq = "[(0,0),(2,0),(2,2),(0,2)]";
    const string[][] expected = [
        ["(1,1)", sq, "[" ~ sq ~ ",[(0.5,0.5)]]", "[[" ~ sq ~ "],[[(5,5)]]]"],
        ["(-1.5,3)", "[]", "[]", "[]"],
        ["(0.25,-0.75)", "[]", "[]", "[]"],
    ];
    enforce(rows == expected, "rows: " ~ rows.to!string);

    const back = conn.queryRow!Shape("SELECT * FROM geo_ins WHERE id = 1");
    enforce(back.center == GeoPoint(1, 1) && back.ring == square && back.area.length == 2 && back.areas[1] == [
        [GeoPoint(5, 5)]
    ], "struct round trip");
    const distance = conn.queryValue!double("SELECT L2Distance(" ~ formatLiteral(GeoPoint(0, 0)) ~ ", "
            ~ formatLiteral(
                GeoPoint(3, 4)) ~ ")");
    enforce(distance == 5, "literal: " ~ distance.to!string);
}
