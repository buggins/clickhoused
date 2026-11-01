/++
Geo types: `Point`, `Ring`, `LineString`, `MultiLineString`, `Polygon`,
`MultiPolygon` and `MultiPoint` (and `Geometry`, a Variant of them, in
`clickhoused.types.variant`).

They are named aliases of Tuple and Array types (`Point` is
`Tuple(Float64, Float64)`, `Polygon` is `Array(Array(Point))`, ...), sent
with the same wire format, so their columns are `TupleColumn` and
`ArrayColumn`. `GeoPoint` is a D type for a point; arrays of it map to the
other geo types.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.geo;

/++
A point of the ClickHouse `Point` type.

It maps to `Point` columns (and any `Tuple(Float64, Float64)`) in struct
mapping, `readValue` and inserts; arrays of it map to the other geo types:

$(TABLE
    $(TR $(TH ClickHouse) $(TH D))
    $(TR $(TD `Point`) $(TD `GeoPoint`))
    $(TR $(TD `Ring`, `LineString`, `MultiPoint`) $(TD `GeoPoint[]`))
    $(TR $(TD `Polygon`, `MultiLineString`) $(TD `GeoPoint[][]`))
    $(TR $(TD `MultiPolygon`) $(TD `GeoPoint[][][]`))
)
+/
struct GeoPoint
{
    /// First coordinate (e.g. longitude).
    double x = 0;
    /// Second coordinate (e.g. latitude).
    double y = 0;
}

/// The underlying type of a geo type name, or `null` if `name` is not one.
package string geoUnderlyingType(string name) @safe pure nothrow @nogc
{
    switch (name)
    {
    case "Point":
        return "Tuple(Float64, Float64)";
    case "Ring":
    case "LineString":
    case "MultiPoint":
        return "Array(Point)";
    case "Polygon":
    case "MultiLineString":
        return name == "Polygon" ? "Array(Ring)" : "Array(LineString)";
    case "MultiPolygon":
        return "Array(Polygon)";
    default:
        return null;
    }
}

@safe unittest
{
    assert(geoUnderlyingType("Point") == "Tuple(Float64, Float64)");
    assert(geoUnderlyingType("Polygon") == "Array(Ring)");
    assert(geoUnderlyingType("MultiLineString") == "Array(LineString)");
    assert(geoUnderlyingType("String") is null);
}

// Golden bytes from `clickhouse client -q "SELECT ... FORMAT Native"` (data part), and mapping
@safe unittest
{
    import clickhoused.insert : appendValue;
    import clickhoused.io.buffer : BufferedReader;
    import clickhoused.io.mock : MockTransport;
    import clickhoused.mapping : readValue;
    import clickhoused.types.array : ArrayColumn;
    import clickhoused.types.factory : createColumn;
    import clickhoused.types.tuple : TupleColumn;

    // SELECT CAST((1.5, -2.0) AS Point): the x column, then the y column
    auto t = new MockTransport;
    t.feed([0, 0, 0, 0, 0, 0, 0xf8, 0x3f, 0, 0, 0, 0, 0, 0, 0, 0xc0]);
    auto point = createColumn("p", "Point");
    point.readData(new BufferedReader(t), 1);
    assert(cast(TupleColumn) point && point.typeName == "Point");
    assert(point.getString(0) == "(1.5,-2)" && readValue!GeoPoint(point, 0) == GeoPoint(1.5, -2));

    // SELECT CAST([[(0., 0.), (1., 0.)]] AS Polygon): two levels of offsets, then the points
    t = new MockTransport;
    const ubyte[] offsets = [1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0];
    const ubyte[] xs = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xf0, 0x3f]; // 0.0, 1.0
    t.feed(offsets ~ xs ~ new ubyte[16]); // ys: 0.0, 0.0
    auto polygon = createColumn("g", "Polygon");
    polygon.readData(new BufferedReader(t), 1);
    assert(t.remaining == 0 && polygon.getString(0) == "[[(0,0),(1,0)]]");
    assert((cast(ArrayColumn) polygon).elements.typeName == "Ring");
    assert(readValue!(GeoPoint[][])(polygon, 0) == [[GeoPoint(0, 0), GeoPoint(1, 0)]]);

    // Inserting
    auto multi = createColumn("m", "MultiPolygon");
    appendValue(multi, [[[GeoPoint(0, 0), GeoPoint(2, 0), GeoPoint(2, 2)]], [[GeoPoint(5, 5)]]]);
    assert(multi.getString(0) == "[[[(0,0),(2,0),(2,2)]],[[(5,5)]]]");
    auto line = createColumn("l", "LineString");
    line.appendString("[(1, 2), (3, 4.5)]");
    assert(line.getString(0) == "[(1,2),(3,4.5)]");
}
