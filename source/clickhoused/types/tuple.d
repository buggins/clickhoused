/++
`Tuple(T1, T2, ...)` columns, including named tuples (`Tuple(a T1, b T2)`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.tuple;

import std.variant : Variant;

import clickhoused.exception : ClientException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column : Column, makeVariant;
import clickhoused.types.textlist : parseTextList;

/++
`Tuple(...)` column. As on the wire, each element is a column of its own,
all with the same number of rows; `names` holds the element names of a named
tuple.
+/
final class TupleColumn : Column
{
    /// One column per element.
    Column[] elements;
    /// Element names; empty for a tuple without names.
    string[] names;

    private size_t emptyRows; // the row count of a tuple without elements, `Tuple()`

    /++
    Creates an empty column.

    Params:
        name = column name.
        typeName = ClickHouse type name.
        elements = empty columns of the element types.
        names = element names, or none.
    +/
    this(string name, string typeName, Column[] elements, string[] names = null) @safe pure nothrow
    {
        super(name, typeName);
        this.elements = elements;
        this.names = names;
    }

    override @property size_t length() const @safe pure nothrow
    {
        return elements.length ? elements[0].length : emptyRows;
    }

    /// Whether the elements have names.
    @property bool isNamed() const @safe pure nothrow
    {
        return names.length != 0;
    }

    /++
    The index of the element called `elementName`.

    Throws: `ClientException` if there is no such element.
    +/
    size_t elementIndex(string elementName) const @safe
    {
        foreach (i, n; names)
            if (n == elementName)
                return i;
        throw new ClientException("Column '" ~ name ~ "' (" ~ typeName ~ ") has no element '" ~ elementName ~ "'");
    }

    /// The column of the element called `elementName`.
    Column element(string elementName) @safe
    {
        return elements[elementIndex(elementName)];
    }

    /++
    The element for each of `fieldNames`, the mapped fields of a D struct:
    by name if the tuple is named and has all of them, otherwise by position
    if the counts match.

    Throws: `ClientException` if the struct does not fit the tuple.
    +/
    size_t[] fieldPositions(const string[] fieldNames, string structName) const @safe
    {
        if (isNamed)
        {
            size_t[] positions;
            foreach (fieldName; fieldNames)
                foreach (i, n; names)
                    if (n == fieldName)
                    {
                        positions ~= i;
                        break;
                    }
            if (positions.length == fieldNames.length)
                return positions;
        }
        if (fieldNames.length != elements.length)
            throw new ClientException("Column '" ~ name ~ "' (" ~ typeName ~ ") does not match " ~ structName
                    ~ ": the names differ and the number of elements too");
        auto positions = new size_t[fieldNames.length];
        foreach (i, ref p; positions)
            p = i;
        return positions;
    }

    /// Passes the call on to the elements, in order.
    override void readStatePrefix(BufferedReader reader) @safe
    {
        foreach (e; elements)
            e.readStatePrefix(reader);
    }

    /// ditto
    override void writeStatePrefix(BufferedWriter writer) const @safe
    {
        foreach (e; elements)
            e.writeStatePrefix(writer);
    }

    /// Reads each element's column in full, one after another.
    override void readData(BufferedReader reader, size_t rows) @safe
    {
        foreach (e; elements)
            e.readData(reader, rows);
        emptyRows = rows;
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        foreach (e; elements)
            if (e.length != length)
                throw new ClientException("Column '" ~ name ~ "': tuple elements differ in length");
        foreach (e; elements)
            e.writeData(writer);
    }

    /// The elements in ClickHouse's text form, e.g. `(1,'a')`.
    override string getString(size_t row) const @safe
    {
        auto s = "(";
        foreach (i, e; elements)
            s ~= (i ? "," : "") ~ e.getQuotedString(row);
        return s ~ ")";
    }

    /// Tuples are not quoted inside arrays.
    override string getQuotedString(size_t row) const @safe
    {
        return getString(row);
    }

    /// A `Variant` holding a `Variant[]` with the element values.
    override Variant getVariant(size_t row) const @trusted
    {
        // Copying Variants is memory-safe, but std.variant is not annotated @safe
        Variant[] values;
        foreach (e; elements)
            values ~= e.getVariant(row);
        return makeVariant(values);
    }

    override void truncate(size_t length) @safe
    {
        foreach (e; elements)
            e.truncate(length);
        if (length < emptyRows)
            emptyRows = length;
    }

    /// Appends the default value of every element.
    override void appendDefault() @safe
    {
        const before = length;
        scope (failure)
            truncate(before);
        foreach (e; elements)
            e.appendDefault();
        emptyRows = before + 1;
    }

    /// Ends a row made of one value appended to each element.
    void endRow() @safe
    {
        foreach (e; elements)
            if (e.length != elements[0].length)
                throw new ClientException("Column '" ~ name ~ "': tuple elements differ in length");
        emptyRows++;
    }

    /++
    Appends a tuple given in ClickHouse's text form, e.g. `(1, 'a')` or
    `(1, [2, 3], NULL)`. Each element is parsed by its column.
    +/
    override void appendString(string value) @safe
    {
        const before = length;
        scope (failure)
            truncate(before);
        const items = parseTextList(value, '(', ')', this, "a tuple");
        if (items.length != elements.length)
            throw appendError("string", value);
        foreach (i, item; items)
            item.appendTo(elements[i]);
        emptyRows = before + 1;
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        auto other = sameKind!TupleColumn(source);
        if (other.elements.length != elements.length)
            throw new ClientException("Column '" ~ name ~ "': cannot copy values of a different tuple type");
        const before = length;
        scope (failure)
            truncate(before);
        foreach (i, e; elements)
            e.appendFrom(other.elements[i], row);
        emptyRows = before + 1;
    }
}

///
@safe unittest
{
    import clickhoused.types.factory : createColumn;

    auto point = cast(TupleColumn) createColumn("p", "Tuple(x Float64, y Float64)");
    point.appendString("(1.5, -2)");
    assert(point.getString(0) == "(1.5,-2)");
    assert(point.element("y").getDouble(0) == -2);
}

// Golden bytes from `clickhouse client -q "SELECT CAST((1, 'x') AS Tuple(a UInt8, b String)) FROM numbers(2)
// FORMAT Native"` (data part only): each element column in full, one after another
@safe unittest
{
    import clickhoused.io.mock : MockTransport;
    import clickhoused.types.factory : createColumn;

    const bytes = cast(const(ubyte)[])[1, 1, 1, 'x', 1, 'x'];
    auto t = new MockTransport;
    t.feed(bytes);
    auto c = cast(TupleColumn) createColumn("t", "Tuple(a UInt8, b String)");
    c.readData(new BufferedReader(t), 2);
    assert(c.length == 2 && c.getString(1) == "(1,'x')" && c.isNamed && c.names == ["a", "b"]);

    auto w = new MockTransport;
    auto writer = new BufferedWriter(w);
    c.writeData(writer);
    writer.flush();
    assert(w.written == bytes);
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.types.factory : createColumn;

    // Text as ClickHouse prints it: nested values quoted like inside arrays
    auto c = cast(TupleColumn) createColumn("t", "Tuple(Date, Nullable(String), Array(UInt8), Tuple(Int8, String))");
    c.appendString("('2025-10-29', NULL, [1, 2], (-1, 'it''s'))");
    c.appendDefault();
    assert(c.getString(0) == `('2025-10-29',NULL,[1,2],(-1,'it\'s'))`);
    assert(c.getString(1) == "('1970-01-01',NULL,[],(0,''))");
    assert(!c.isNamed && c.length == 2);

    foreach (bad; [
        "(1)", "('2025-10-29', NULL, [1], (1, 'a'), 5)", "('x', NULL, [], (1, 'a'))", "[]"
    ])
        assertThrown!ClientException(c.appendString(bad), bad);
    assert(c.length == 2); // failed appends left no trace
    foreach (e; c.elements)
        assert(e.length == 2);

    auto copy = cast(TupleColumn) createColumn("t", c.typeName);
    copy.appendFrom(c, 0);
    assert(copy.getString(0) == c.getString(0));
    assertThrown!ClientException(c.element("nope"));
}
