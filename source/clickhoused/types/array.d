/++
`Array(T)` columns.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.array;

import std.variant : Variant;

import clickhoused.exception : ClientException, ProtocolException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column : appendFast, Column, makeVariant, readChunkRows, readFixedValues, writeFixedValues;
import clickhoused.types.textlist : parseTextList;

/++
`Array(T)` column. As on the wire, the elements of all rows are kept in one
column of type `T`, and `offsets` marks where each row ends: row `i` holds
`elements[offsets[i - 1] .. offsets[i]]` (from 0 for the first row).

Nested arrays (`Array(Array(T))`) have an `ArrayColumn` as `elements`.
+/
final class ArrayColumn : Column
{
    /// End of each row in `elements`: cumulative element counts.
    ulong[] offsets;
    private ulong[] spareOffsets; // room for appends; see `appendFast`
    /// The elements of all rows, in order.
    Column elements;

    /++
    Creates an empty column.

    Params:
        name = column name.
        typeName = ClickHouse type name.
        elements = empty column of the element type.
    +/
    this(string name, string typeName, Column elements) @safe pure nothrow
    {
        super(name, typeName);
        this.elements = elements;
    }

    override @property size_t length() const @safe pure nothrow
    {
        return offsets.length;
    }

    /// Index in `elements` of the first element of `row`.
    size_t rowStart(size_t row) const @safe pure nothrow
    {
        return row ? cast(size_t) offsets[row - 1] : 0;
    }

    /// Index in `elements` just past the last element of `row`.
    size_t rowEnd(size_t row) const @safe pure nothrow
    {
        return cast(size_t) offsets[row];
    }

    /// Number of elements in `row`.
    size_t rowLength(size_t row) const @safe pure nothrow
    {
        return rowEnd(row) - rowStart(row);
    }

    override void readData(BufferedReader reader, size_t rows) @safe
    {
        offsets = null;
        while (offsets.length < rows)
        {
            const start = offsets.length;
            const count = rows - start < readChunkRows ? rows - start : readChunkRows;
            offsets.length = start + count;
            readFixedValues(reader, offsets[start .. $]);
        }
        ulong previous;
        foreach (end; offsets)
        {
            if (end < previous)
                throw new ProtocolException("Column '" ~ name ~ "': array offsets decrease");
            previous = end;
        }
        if (previous > size_t.max)
            throw new ProtocolException("Column '" ~ name ~ "': too many array elements");
        // The element readers grow their storage with the data actually received,
        // so a corrupt element count cannot cause a huge allocation here
        elements.readData(reader, cast(size_t) previous);
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        const total = offsets.length ? offsets[$ - 1] : 0;
        if (elements.length != total)
            throw new ClientException("Column '" ~ name ~ "': array offsets and elements differ in length");
        writeFixedValues(writer, offsets);
        elements.writeData(writer);
    }

    /// The elements in ClickHouse's text form, e.g. `[1,2,3]` or `['a','b']`.
    override string getString(size_t row) const @safe
    {
        auto s = "[";
        foreach (i; rowStart(row) .. rowEnd(row))
            s ~= (i > rowStart(row) ? "," : "") ~ elements.getQuotedString(i);
        return s ~ "]";
    }

    /// The elements as raw bytes; only for `Array(UInt8)`.
    override const(ubyte)[] getBytes(size_t row) const @safe
    {
        import clickhoused.types.numeric : UInt8Column;

        if (auto bytes = cast(const UInt8Column) elements)
            return bytes.data[rowStart(row) .. rowEnd(row)];
        throw conversionError(row, "bytes");
    }

    /// A `Variant` holding a `Variant[]` with the element values (see `Column.getVariant`).
    override Variant getVariant(size_t row) const @trusted
    {
        // Copying Variants is memory-safe, but std.variant is not annotated @safe
        Variant[] values;
        foreach (i; rowStart(row) .. rowEnd(row))
            values ~= elements.getVariant(i);
        return makeVariant(values);
    }

    override void truncate(size_t length) @safe
    {
        if (length >= offsets.length)
            return;
        offsets.length = length;
        elements.truncate(length ? cast(size_t) offsets[$ - 1] : 0);
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        auto other = sameKind!ArrayColumn(source);
        const before = elements.length;
        scope (failure)
            elements.truncate(before);
        foreach (i; other.rowStart(row) .. other.rowEnd(row))
            elements.appendFrom(other.elements, i);
        endRow();
    }

    /// Passes the call on to the elements: their prefix comes before the offsets.
    override void readStatePrefix(BufferedReader reader) @safe
    {
        elements.readStatePrefix(reader);
    }

    /// ditto
    override void writeStatePrefix(BufferedWriter writer) const @safe
    {
        elements.writeStatePrefix(writer);
    }

    /// Appends an empty array.
    override void appendDefault() @safe
    {
        appendFast(offsets, spareOffsets, elements.length);
    }

    /// Ends a row made of the elements appended since the previous row.
    void endRow() @safe
    {
        appendFast(offsets, spareOffsets, elements.length);
    }

    /// Appends the bytes as an array of numbers.
    override void appendBytes(const(ubyte)[] value) @safe
    {
        const before = elements.length;
        scope (failure)
            elements.truncate(before);
        foreach (b; value)
            elements.appendUlong(b);
        endRow();
    }

    /++
    Appends an array given in ClickHouse's text form, e.g. `[1, 2, 3]`,
    `['a', 'it\'s']`, `[[1], []]` or `[1, NULL]`. Quoted and unquoted elements
    are parsed by the element column, so `['1']` works for numbers too.
    +/
    override void appendString(string value) @safe
    {
        const before = elements.length;
        scope (failure)
            elements.truncate(before);
        foreach (element; parseTextList(value, '[', ']', this, "an array"))
            element.appendTo(elements);
        endRow();
    }
}

///
@safe unittest
{
    import clickhoused.types.factory : createColumn;

    auto c = cast(ArrayColumn) createColumn("tags", "Array(String)");
    c.appendString("['a', 'it\\'s']");
    c.appendDefault(); // an empty array
    assert(c.length == 2 && c.rowLength(0) == 2 && c.rowLength(1) == 0);
    assert(c.getString(0) == `['a','it\'s']` && c.getString(1) == "[]");
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
        auto c = createColumn("a", type);
        c.readData(new BufferedReader(t), rows);
        assert(t.remaining == 0, type);
        return c;
    }

    // SELECT [1,2,3]::Array(UInt8)
    auto a = read("Array(UInt8)", 1, [3, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3]);
    assert(a.getString(0) == "[1,2,3]" && a.getBytes(0) == [1, 2, 3]);

    // SELECT ['x', NULL]::Array(Nullable(String))
    auto n = read("Array(Nullable(String))", 1, [2, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 'x', 0]);
    assert(n.getString(0) == "['x',NULL]");

    // SELECT [[1,2],[],[3]]::Array(Array(Int8))
    auto nested = read("Array(Array(Int8))", 1, [
        3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0,
        0, 1, 2, 3
    ]);
    assert(nested.getString(0) == "[[1,2],[],[3]]");

    // Writing gives the same bytes
    auto t = new MockTransport;
    auto w = new BufferedWriter(t);
    nested.writeData(w);
    w.flush();
    assert(t.written == [
        3, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0,
        0, 1, 2, 3
    ]);
}

// Decreasing offsets and truncated data are protocol errors
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.exception : ConnectionException;
    import clickhoused.io.mock : MockTransport;
    import clickhoused.types.factory : createColumn;

    auto t = new MockTransport;
    t.feed([5, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0]);
    assertThrown!ProtocolException(createColumn("a", "Array(UInt8)").readData(new BufferedReader(t), 2));

    // Offsets claim 2^40 elements, but the stream ends: fails without allocating them
    t = new MockTransport;
    t.feed([0, 0, 0, 0, 0, 1, 0, 0, 1, 2]);
    bool failed;
    try
        createColumn("a", "Array(UInt8)").readData(new BufferedReader(t), 1);
    catch (ConnectionException)
        failed = true;
    catch (ProtocolException)
        failed = true;
    assert(failed);
}

// Text parsing, getString of quoted types, and failed appends
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.types.factory : createColumn;

    auto ints = cast(ArrayColumn) createColumn("a", "Array(Nullable(Int32))");
    ints.appendString(" [ 1 , NULL,'-3' ] ");
    assert(ints.getString(0) == "[1,NULL,-3]");
    foreach (bad; ["", "[", "[1,", "[1 2]", "[1]x", "1", "[,]", "['a"])
        assertThrown!ClientException(ints.appendString(bad), bad);
    assertThrown!ClientException(ints.appendString("[1, 99999999999]")); // out of range
    assert(ints.length == 1 && ints.elements.length == 3); // failed appends left no trace

    auto quotes = cast(ArrayColumn) createColumn("q", "Array(String)");
    quotes.appendString(`['it''s', 'a\'b']`);
    assert(quotes.getString(0) == `['it\'s','a\'b']`);

    auto fixed = createColumn("f", "Array(FixedString(3))");
    fixed.appendString("['ab']");
    assert(fixed.getString(0) == `['ab\0']`); // as the server prints it: with the zero padding

    auto nested = cast(ArrayColumn) createColumn("a", "Array(Array(String))");
    nested.appendString(`[['a]b', '\x41\n'], [], ['']]`);
    assert(nested.getString(0) == `[['a]b','A\n'],[],['']]`);

    auto dates = createColumn("d", "Array(Date)");
    dates.appendString("['2025-10-29']");
    assert(dates.getString(0) == "['2025-10-29']");

    auto bytes = cast(ArrayColumn) createColumn("b", "Array(UInt8)");
    bytes.appendBytes([7, 8]);
    assert(bytes.getString(0) == "[7,8]");
    bytes.truncate(0);
    assert(bytes.length == 0 && bytes.elements.length == 0);
}
