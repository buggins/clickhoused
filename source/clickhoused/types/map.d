/++
`Map(K, V)` columns.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.map;

import std.variant : Variant;

import clickhoused.exception : ClientException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.array : ArrayColumn;
import clickhoused.types.column : Column, makeVariant;
import clickhoused.types.textlist : parseTextPairs;
import clickhoused.types.tuple : TupleColumn;

/++
`Map(K, V)` column. On the wire a map is an `Array(Tuple(K, V))`, and so is
`entries` here: the keys and values of all rows are in `keys` and `values`,
and row `i` holds the entries `rowStart(i) .. rowEnd(i)`. Like ClickHouse, a
map keeps its entries in order and may contain a key more than once.
+/
final class MapColumn : Column
{
    /// The entries as `Array(Tuple(keys, values))`, as on the wire.
    ArrayColumn entries;

    /++
    Creates an empty column.

    Params:
        name = column name.
        typeName = ClickHouse type name.
        keys = empty column of the key type.
        values = empty column of the value type.
    +/
    this(string name, string typeName, Column keys, Column values) @safe pure nothrow
    {
        super(name, typeName);
        auto pairs = new TupleColumn(name, "Tuple(" ~ keys.typeName ~ ", " ~ values.typeName ~ ")", [
            keys, values
        ], ["keys", "values"]);
        entries = new ArrayColumn(name, "Array(" ~ pairs.typeName ~ ")", pairs);
    }

    /// The keys of all rows.
    @property inout(Column) keys() inout @safe pure nothrow
    {
        return (cast(inout TupleColumn) entries.elements).elements[0];
    }

    /// The values of all rows.
    @property inout(Column) values() inout @safe pure nothrow
    {
        return (cast(inout TupleColumn) entries.elements).elements[1];
    }

    override @property size_t length() const @safe pure nothrow
    {
        return entries.length;
    }

    /// Index in `keys` and `values` of the first entry of `row`.
    size_t rowStart(size_t row) const @safe pure nothrow
    {
        return entries.rowStart(row);
    }

    /// Index in `keys` and `values` just past the last entry of `row`.
    size_t rowEnd(size_t row) const @safe pure nothrow
    {
        return entries.rowEnd(row);
    }

    /// Number of entries in `row`.
    size_t rowLength(size_t row) const @safe pure nothrow
    {
        return entries.rowLength(row);
    }

    override void readStatePrefix(BufferedReader reader) @safe
    {
        entries.readStatePrefix(reader);
    }

    override void writeStatePrefix(BufferedWriter writer) const @safe
    {
        entries.writeStatePrefix(writer);
    }

    override void readData(BufferedReader reader, size_t rows) @safe
    {
        entries.readData(reader, rows);
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        entries.writeData(writer);
    }

    /// The entries in ClickHouse's text form, e.g. `{'a':1,'b':2}`.
    override string getString(size_t row) const @safe
    {
        auto s = "{";
        foreach (i; rowStart(row) .. rowEnd(row))
            s ~= (i > rowStart(row) ? "," : "") ~ keys.getQuotedString(i) ~ ":" ~ values.getQuotedString(i);
        return s ~ "}";
    }

    /// Maps are not quoted inside arrays.
    override string getQuotedString(size_t row) const @safe
    {
        return getString(row);
    }

    /// A `Variant` holding a `Variant[][]`: `[key, value]` for each entry, in order.
    override Variant getVariant(size_t row) const @trusted
    {
        // Copying Variants is memory-safe, but std.variant is not annotated @safe
        Variant[][] pairs;
        foreach (i; rowStart(row) .. rowEnd(row))
            pairs ~= [keys.getVariant(i), values.getVariant(i)];
        return makeVariant(pairs);
    }

    override void truncate(size_t length) @safe
    {
        entries.truncate(length);
    }

    /// Appends an empty map.
    override void appendDefault() @safe
    {
        entries.appendDefault();
    }

    /// Ends a row made of the keys and values appended since the previous row.
    void endRow() @safe
    {
        if (keys.length != values.length)
            throw new ClientException("Column '" ~ name ~ "': map keys and values differ in length");
        entries.endRow();
    }

    /++
    Appends a map given in ClickHouse's text form, e.g. `{'a': 1, 'b': 2}`.
    Keys and values are parsed by their columns.
    +/
    override void appendString(string value) @safe
    {
        const before = keys.length;
        scope (failure)
        {
            keys.truncate(before);
            values.truncate(before);
        }
        foreach (pair; parseTextPairs(value, this))
        {
            pair[0].appendTo(keys);
            pair[1].appendTo(values);
        }
        endRow();
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        entries.appendFrom(sameKind!MapColumn(source).entries, row);
    }
}

///
@safe unittest
{
    import clickhoused.types.factory : createColumn;

    auto c = cast(MapColumn) createColumn("tags", "Map(String, UInt32)");
    c.appendString("{'a': 1, 'b': 2}");
    c.appendDefault(); // an empty map
    assert(c.getString(0) == "{'a':1,'b':2}" && c.getString(1) == "{}");
    assert(c.rowLength(0) == 2 && c.keys.getString(1) == "b" && c.values.getUlong(1) == 2);
}

// Golden bytes from `clickhouse client -q "SELECT ... FORMAT Native"` (data part only)
@safe unittest
{
    import clickhoused.io.mock : MockTransport;
    import clickhoused.types.factory : createColumn;

    Column read(string type, size_t rows, const(ubyte)[] bytes)
    {
        auto t = new MockTransport;
        t.feed(bytes);
        auto r = new BufferedReader(t);
        auto c = createColumn("m", type);
        c.readStatePrefix(r);
        c.readData(r, rows);
        assert(t.remaining == 0, type);
        return c;
    }

    // SELECT map('a', 1, 'b', 2): offsets, keys, values
    const plain = cast(const(ubyte)[])[2, 0, 0, 0, 0, 0, 0, 0, 1, 'a', 1, 'b', 1, 2];
    auto m = read("Map(String, UInt8)", 1, plain);
    assert(m.getString(0) == "{'a':1,'b':2}");

    // SELECT CAST(map('x', 1, 'y', 2) AS Map(LowCardinality(String), UInt8)):
    // the key prefix comes before the offsets
    auto lc = read("Map(LowCardinality(String), UInt8)", 1, cast(const(ubyte)[])[
        1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0,
        0, 1, 'x',
        1, 'y', 2, 0, 0, 0, 0, 0, 0, 0, 1, 2, 1, 2
    ]);
    assert(lc.getString(0) == "{'x':1,'y':2}");

    // Writing gives the same bytes
    auto w = new MockTransport;
    auto writer = new BufferedWriter(w);
    m.writeStatePrefix(writer);
    m.writeData(writer);
    writer.flush();
    assert(w.written == plain);
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.types.factory : createColumn;

    auto c = cast(MapColumn) createColumn("m", "Map(Date, Array(Nullable(String)))");
    c.appendString("{'2025-10-29': ['a', NULL], '1970-01-01': []}");
    assert(c.getString(0) == "{'2025-10-29':['a',NULL],'1970-01-01':[]}");
    foreach (bad; ["{'x': []}", "{'2025-10-29': 5}", "{'2025-10-29'}", "[]"])
        assertThrown!ClientException(c.appendString(bad), bad);
    assert(c.length == 1 && c.keys.length == 2 && c.values.length == 2); // failed appends left no trace

    auto nested = createColumn("n", "Map(String, Map(String, UInt8))");
    nested.appendString("{'k': {'n': 1}}");
    assert(nested.getString(0) == "{'k':{'n':1}}");
    auto copy = createColumn("n", nested.typeName);
    copy.appendFrom(nested, 0);
    assert(copy.getString(0) == "{'k':{'n':1}}");
}
