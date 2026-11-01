/++
`Variant(T1, ..., Tn)` columns: each row holds a value of one of the
alternative types, or NULL. Also the `Geometry` type, a Variant of the geo
types.

The server lists the alternatives sorted by name (it turns
`Variant(UInt8, String)` into `Variant(String, UInt8)`), and that order
numbers them. The type exists since ClickHouse 24.1 (production-ready since
25.3).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.variant;

import core.time : Duration;
import std.datetime.date : Date;
import std.datetime.systime : SysTime;
import std.uuid : UUID;
import std.variant : Variant;

import clickhoused.exception : ClientException, ProtocolException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column : Column, readChunkRows;

/++
The `Geometry` type: a Variant of the geo types, in a fixed order that numbers
them (`MultiPoint`, the newest, comes last).
+/
package enum geometryUnderlyingType = "Variant(LineString, MultiLineString, MultiPolygon, Point, Polygon, Ring, "
    ~ "MultiPoint)";

/++
`Variant(...)` column.

As on the wire, `discriminators` holds the alternative of each row (an index
into `variants`, or `nullDiscriminator`), and each alternative's column holds
only the values of the rows that have it, in row order.

Getters return the value of the row's alternative and throw
`ClientException` for NULL, as for a `Nullable` column. Appends choose the
alternative from the kind of value (e.g. `appendLong` the first integer
alternative it fits in, then decimal and floating-point ones; `appendString`
a string alternative, else the first one that parses the text); `appendTo`
chooses explicitly.
+/
final class VariantColumn : Column
{
    /// The discriminator of a NULL row.
    enum ubyte nullDiscriminator = 255;

    /// The alternative of each row: an index into `variants`, or `nullDiscriminator`.
    ubyte[] discriminators;
    /// One column per alternative type, in the order of the type name.
    Column[] variants;

    private size_t[] positions; // the row's index in its alternative's column

    /++
    Creates an empty column.

    Params:
        name = column name.
        typeName = ClickHouse type name.
        variants = empty columns of the alternative types, in the order of the type name (at most 255).
    +/
    this(string name, string typeName, Column[] variants) @safe pure nothrow
    {
        assert(variants.length < nullDiscriminator);
        super(name, typeName);
        this.variants = variants;
    }

    override @property size_t length() const @safe pure nothrow
    {
        return discriminators.length;
    }

    /// The index of the alternative of type `variantTypeName` (as in the type name).
    /// Throws: `ClientException` if there is none.
    size_t variantIndex(string variantTypeName) const @safe
    {
        foreach (i, v; variants)
            if (v.typeName == variantTypeName)
                return i;
        throw new ClientException("Column '" ~ name ~ "' (" ~ typeName ~ ") has no alternative " ~ variantTypeName);
    }

    /// The type name of the value in `row`, or `null` for NULL (the server's `variantType` says `None`).
    string variantTypeName(size_t row) const @safe
    {
        const d = discriminators[row];
        return d == nullDiscriminator ? null : variants[d].typeName;
    }

    /// The position of the value of `row` in the column of its alternative (meaningless for NULL).
    size_t position(size_t row) const @safe pure nothrow
    {
        return positions[row];
    }

    /// Reads the discriminators mode (only the basic one, 0, is used in the native format) and passes the call on.
    override void readStatePrefix(BufferedReader reader) @safe
    {
        import std.conv : to;

        const mode = reader.readFixed!ulong();
        if (mode != 0)
            throw new ProtocolException(
                    "Column '" ~ name ~ "' (" ~ typeName
                    ~ "): unsupported Variant discriminators mode " ~ mode.to!string);
        foreach (v; variants)
            v.readStatePrefix(reader);
    }

    /// ditto
    override void writeStatePrefix(BufferedWriter writer) const @safe
    {
        writer.writeFixed!ulong(0);
        foreach (v; variants)
            v.writeStatePrefix(writer);
    }

    /// Reads the discriminators, then each alternative's values.
    override void readData(BufferedReader reader, size_t rows) @safe
    {
        import std.conv : to;

        discriminators = null;
        positions = null;
        auto counts = new size_t[variants.length];
        while (discriminators.length < rows)
        {
            const start = discriminators.length;
            const count = rows - start < readChunkRows ? rows - start : readChunkRows;
            discriminators.length = start + count;
            positions.length = start + count;
            reader.readExact(discriminators[start .. $]);
            foreach (i, d; discriminators[start .. $])
            {
                if (d == nullDiscriminator)
                    continue;
                if (d >= variants.length)
                    throw new ProtocolException(
                            "Column '" ~ name ~ "' (" ~ typeName ~ "): invalid discriminator "
                            ~ d.to!string);
                positions[start + i] = counts[d]++;
            }
        }
        foreach (i, v; variants)
            v.readData(reader, counts[i]);
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        auto counts = new size_t[variants.length];
        foreach (d; discriminators)
            if (d != nullDiscriminator)
                counts[d]++;
        foreach (i, v; variants)
            if (v.length != counts[i])
                throw new ClientException(
                        "Column '" ~ name ~ "': alternative " ~ v.typeName
                        ~ " does not match the discriminators");
        writer.writeBytes(discriminators);
        foreach (v; variants)
            v.writeData(writer);
    }

    override @property bool isNullable() const @safe pure nothrow
    {
        return true;
    }

    override bool isNull(size_t row) const @safe
    {
        return discriminators[row] == nullDiscriminator;
    }

    /// The column of the alternative of `row`.
    private const(Column) held(size_t row) const @safe
    {
        import std.conv : to;

        if (discriminators[row] == nullDiscriminator)
            throw new ClientException("Column '" ~ name ~ "', row " ~ row.to!string ~ ": value is NULL");
        return variants[discriminators[row]];
    }

    override long getLong(size_t row) const @safe
    {
        return held(row).getLong(positions[row]);
    }

    override ulong getUlong(size_t row) const @safe
    {
        return held(row).getUlong(positions[row]);
    }

    override double getDouble(size_t row) const @safe
    {
        return held(row).getDouble(positions[row]);
    }

    override bool getBool(size_t row) const @safe
    {
        return held(row).getBool(positions[row]);
    }

    /// The text of the held value.
    override string getString(size_t row) const @safe
    {
        return held(row).getString(positions[row]);
    }

    override const(ubyte)[] getBytes(size_t row) const @safe
    {
        return held(row).getBytes(positions[row]);
    }

    override Date getDate(size_t row) const @safe
    {
        return held(row).getDate(positions[row]);
    }

    override SysTime getSysTime(size_t row) const @safe
    {
        return held(row).getSysTime(positions[row]);
    }

    override UUID getUUID(size_t row) const @safe
    {
        return held(row).getUUID(positions[row]);
    }

    override Duration getDuration(size_t row) const @safe
    {
        return held(row).getDuration(positions[row]);
    }

    /// `NULL`, or the held value as its type writes it inside an array (`[1,'a',NULL]`).
    override string getQuotedString(size_t row) const @safe
    {
        return isNull(row) ? "NULL" : variants[discriminators[row]].getQuotedString(positions[row]);
    }

    /// The held value's `Variant`, or an empty one for NULL.
    override Variant getVariant(size_t row) const @safe
    {
        return isNull(row) ? Variant.init : variants[discriminators[row]].getVariant(positions[row]);
    }

    override void truncate(size_t length) @safe
    {
        if (length >= discriminators.length)
            return;
        auto counts = new size_t[variants.length];
        foreach (d; discriminators[0 .. length])
            if (d != nullDiscriminator)
                counts[d]++;
        foreach (i, v; variants)
            v.truncate(counts[i]);
        discriminators.length = length;
        positions.length = length;
    }

    /// Appends NULL, the default value of a Variant.
    override void appendDefault() @safe
    {
        appendNull();
    }

    override void appendNull() @safe
    {
        discriminators ~= nullDiscriminator;
        positions ~= 0;
    }

    /++
    Appends a value to the alternative `index`: `append` must add exactly one
    value to the column it is given.

    Example: `column.appendTo(column.variantIndex("String"), (c) { c.appendString("5"); });`
    +/
    void appendTo(size_t index, scope void delegate(Column) @safe append) @safe
    {
        auto target = variants[index];
        const before = target.length;
        append(target);
        if (target.length != before + 1)
        {
            target.truncate(before);
            throw new ClientException("Column '" ~ name ~ "': appendTo must add exactly one value");
        }
        discriminators ~= cast(ubyte) index;
        positions ~= before;
    }

    /// Kinds of alternatives, used to choose where generic appends go.
    private enum Kind
    {
        integer,
        floating,
        decimal,
        text,
        boolean,
        date,
        dateTime,
        uuid,
        time,
        other
    }

    private static Kind kindOf(const Column column) @safe pure
    {
        import std.algorithm.searching : startsWith;

        string t = column.typeName;
        if (t.startsWith("LowCardinality(") && t.length > 16)
            t = t[15 .. $ - 1];
        if (t.startsWith("Int") || t.startsWith("UInt"))
            return Kind.integer;
        if (t.startsWith("Float") || t == "BFloat16")
            return Kind.floating;
        if (t.startsWith("Decimal"))
            return Kind.decimal;
        if (t == "String" || t.startsWith("FixedString") || t.startsWith("Enum"))
            return Kind.text;
        if (t == "Bool")
            return Kind.boolean;
        if (t == "Date" || t == "Date32")
            return Kind.date;
        if (t.startsWith("DateTime"))
            return Kind.dateTime;
        if (t == "UUID")
            return Kind.uuid;
        if (t == "Time" || t.startsWith("Time64"))
            return Kind.time;
        return Kind.other;
    }

    /++
    Appends with `append` to the first alternative of the kinds `kinds` (in
    that order of preference, alternatives of a kind in type order) that
    accepts the value; with `others`, then to any other alternative.
    Returns: whether one accepted it.
    +/
    private bool appendFirst(const Kind[] kinds, bool others, scope void delegate(Column) @safe append) @safe
    {
        bool tryOne(size_t i) @safe
        {
            auto target = variants[i];
            const before = target.length;
            try
                append(target);
            catch (ClientException)
                return false;
            if (target.length != before + 1)
            {
                target.truncate(before);
                return false;
            }
            discriminators ~= cast(ubyte) i;
            positions ~= before;
            return true;
        }

        auto tried = new bool[variants.length];
        foreach (kind; kinds)
            foreach (i, v; variants)
                if (!tried[i] && kindOf(v) == kind)
                {
                    tried[i] = true;
                    if (tryOne(i))
                        return true;
                }
        if (others)
            foreach (i; 0 .. variants.length)
                if (!tried[i] && tryOne(i))
                    return true;
        return false;
    }

    /++
    Appends with `append` to the first alternative that accepts the value
    (`append` throws `ClientException` or adds nothing for the others),
    trying string alternatives last. `appendValue` uses it for values without
    a typed append, such as arrays, structs, `Decimal` or `IPv4`.
    +/
    void appendToAny(scope void delegate(Column) @safe append) @safe
    {
        static immutable Kind[] nonText = [
            Kind.integer, Kind.floating, Kind.decimal, Kind.boolean, Kind.date, Kind.dateTime,
            Kind.uuid,
            Kind.time, Kind.other
        ];
        if (!appendFirst(nonText ~ Kind.text, false, append))
            throw new ClientException("Column '" ~ name ~ "' (" ~ typeName ~ "): no alternative accepts the value");
    }

    override void appendLong(long value) @safe
    {
        if (!appendFirst([Kind.integer, Kind.decimal, Kind.floating], false, (c) => c.appendLong(value)))
            throw appendError("long", value);
    }

    override void appendUlong(ulong value) @safe
    {
        if (!appendFirst([Kind.integer, Kind.decimal, Kind.floating], false, (c) => c.appendUlong(value)))
            throw appendError("ulong", value);
    }

    override void appendDouble(double value) @safe
    {
        if (!appendFirst([Kind.floating, Kind.decimal, Kind.integer], false, (c) => c.appendDouble(value)))
            throw appendError("double", value);
    }

    override void appendBool(bool value) @safe
    {
        if (!appendFirst([Kind.boolean, Kind.integer], false, (c) => c.appendBool(value)))
            throw appendError("bool", value);
    }

    /// Appends to a string alternative, else to the first alternative that parses `value`.
    override void appendString(string value) @safe
    {
        if (!appendFirst([Kind.text], true, (c) => c.appendString(value)))
            throw appendError("string", value);
    }

    /++
    Appends an element of a text list (`[1, 'a']`): quoted text prefers string
    alternatives, bare text (numbers, nested lists) the others.
    +/
    package(clickhoused) void appendTextElement(string text, bool quoted) @safe
    {
        static immutable Kind[] nonText = [
            Kind.integer, Kind.floating, Kind.decimal, Kind.boolean, Kind.date, Kind.dateTime,
            Kind.uuid,
            Kind.time, Kind.other
        ];
        if (!appendFirst(quoted ? [Kind.text] : nonText, true, (c) => c.appendString(text)))
            throw appendError("string", text);
    }

    override void appendBytes(const(ubyte)[] value) @safe
    {
        if (!appendFirst([Kind.text], false, (c) => c.appendBytes(value)))
            throw appendError("bytes", value.length);
    }

    override void appendDate(Date value) @safe
    {
        if (!appendFirst([Kind.date, Kind.dateTime], false, (c) => c.appendDate(value)))
            throw appendError("Date", value);
    }

    override void appendSysTime(SysTime value) @safe
    {
        if (!appendFirst([Kind.dateTime], false, (c) => c.appendSysTime(value)))
            throw appendError("SysTime", value);
    }

    override void appendUUID(UUID value) @safe
    {
        if (!appendFirst([Kind.uuid], false, (c) => c.appendUUID(value)))
            throw appendError("UUID", value);
    }

    override void appendDuration(Duration value) @safe
    {
        if (!appendFirst([Kind.time], false, (c) => c.appendDuration(value)))
            throw appendError("Duration", value);
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        auto other = sameKind!VariantColumn(source);
        if (other.variants.length != variants.length)
            throw new ClientException("Column '" ~ name ~ "': cannot copy values of a different Variant type");
        const d = other.discriminators[row];
        if (d == nullDiscriminator)
            return appendNull();
        const before = variants[d].length;
        variants[d].appendFrom(other.variants[d], other.positions[row]);
        discriminators ~= d;
        positions ~= before;
    }
}

///
@system unittest
{
    import clickhoused.types.factory : createColumn;

    auto v = cast(VariantColumn) createColumn("v", "Variant(String, UInt8)");
    v.appendLong(1); // to UInt8
    v.appendString("ab"); // to String
    v.appendNull();
    assert(v.discriminators == [1, 0, VariantColumn.nullDiscriminator]);
    assert(v.getString(0) == "1" && v.getString(1) == "ab" && v.isNull(2));
    assert(v.variantTypeName(0) == "UInt8" && v.getVariant(1).get!string == "ab");
    assert(v.getQuotedString(1) == "'ab'" && v.getQuotedString(2) == "NULL");
}

// Golden bytes from `SELECT arrayJoin([1::Variant(UInt8, String), 'ab', NULL]) FORMAT Native` (prefix and data)
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.io.mock : MockTransport;
    import clickhoused.types.factory : createColumn;

    const bytes = cast(const(ubyte)[])[0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0xff, 2, 'a', 'b', 1];
    auto t = new MockTransport;
    t.feed(bytes);
    auto reader = new BufferedReader(t);
    auto v = cast(VariantColumn) createColumn("v", "Variant(String, UInt8)");
    v.readStatePrefix(reader);
    v.readData(reader, 3);
    assert(v.getString(0) == "1" && v.getLong(0) == 1 && v.getString(1) == "ab" && v.isNull(2));
    assert(v.position(1) == 0 && v.variants[0].length == 1 && v.variants[1].length == 1);
    assertThrown!ClientException(v.getString(2));

    auto w = new MockTransport;
    auto writer = new BufferedWriter(w);
    v.writeStatePrefix(writer);
    v.writeData(writer);
    writer.flush();
    assert(w.written == bytes);

    // Bad input
    auto bad = new MockTransport;
    bad.feed(cast(const(ubyte)[])[1, 0, 0, 0, 0, 0, 0, 0]);
    assertThrown!ProtocolException(v.readStatePrefix(new BufferedReader(bad)));
    bad.feed(cast(const(ubyte)[])[5]);
    assertThrown!ProtocolException(v.readData(new BufferedReader(bad), 1));
}

@safe unittest
{
    import core.time : seconds;
    import std.exception : assertThrown;
    import clickhoused.types.factory : createColumn;

    // Generic appends choose the alternative by kind; values that fit nowhere leave the column unchanged
    auto v = cast(VariantColumn) createColumn("v", "Variant(Date, Float64, Int8, String, Time)");
    v.appendLong(5); // Int8
    v.appendLong(1000); // too big for Int8: Float64
    v.appendDouble(2.5); // Float64
    v.appendString("x"); // String
    v.appendDate(Date(2020, 1, 2));
    v.appendDuration(61.seconds);
    v.appendTo(v.variantIndex("String"), (c) { c.appendString("5"); });
    assert(v.discriminators == [2, 1, 1, 3, 0, 4, 3]);
    assert(v.getString(1) == "1000" && v.getString(5) == "00:01:01" && v.getString(6) == "5");
    import std.uuid : randomUUID;

    assertThrown!ClientException(v.appendUUID(randomUUID())); // no UUID alternative
    assertThrown!ClientException(v.appendTo(0, (c) {}));
    assert(v.length == 7);

    // Text lists: bare elements prefer non-string alternatives
    auto a = createColumn("a", "Array(Variant(String, UInt64))");
    a.appendString("[1, 'a', NULL, '2']");
    assert(a.getString(0) == "[1,'a',NULL,'2']");
    auto e = cast(VariantColumn)(cast(clickhoused.types.array.ArrayColumn) a).elements;
    assert(e.discriminators == [1, 0, VariantColumn.nullDiscriminator, 0]);

    // truncate and appendFrom
    v.truncate(3);
    assert(v.length == 3 && v.variants[3].length == 0 && v.variants[1].length == 2);
    auto copy = cast(VariantColumn) createColumn("v", "Variant(Date, Float64, Int8, String, Time)");
    v.appendNull();
    copy.appendFrom(v, 2);
    copy.appendFrom(v, 3);
    assert(copy.getString(0) == "2.5" && copy.isNull(1));
    assertThrown!ClientException(copy.appendFrom(e, 0)); // a different Variant type
}
