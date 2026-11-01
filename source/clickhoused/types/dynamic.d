/++
`Dynamic` columns: each row holds a value of any type, or NULL; the types are
listed in the data itself, per block.

The type exists since ClickHouse 24.5 (production-ready since 25.3). At this
client's protocol revision the server sends it in one of two forms:
$(UL
    $(LI the flattened form, a type list with a plain column per type, which
        `Connection` asks for on servers 25.6 and newer (see
        `ConnectionOptions.simpleNativeFormats`);)
    $(LI otherwise the V1 form: a `Variant` of the types plus `SharedVariant`,
        where values of types beyond the column's `max_types` are kept in a
        binary encoding. Such values can't be read by this client: reading
        one throws `ClientException`.)
)
Values are written in the V1 form without `SharedVariant` values, which every
server version accepts.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.dynamic;

import core.time : Duration;
import std.datetime.date : Date;
import std.datetime.systime : SysTime;
import std.uuid : UUID;
import std.variant : Variant;

import clickhoused.exception : ClientException, ProtocolException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column : Column, readChunkRows;
import clickhoused.types.string : StringColumn;
import clickhoused.types.variant : VariantColumn;

/++
`Dynamic` column.

`values` holds the data as a Variant column whose alternatives are the types
of the values (in no particular order): `dynamicTypeName(row)` gives the type
of a row, getters and text go to the value. A NULL row has no type.

Appends choose a type from the kind of value, as the server infers types of
inserted text: `appendLong` `Int64`, `appendUlong` `UInt64`, `appendDouble`
`Float64`, `appendBool` `Bool`, `appendString` `String`, `appendDate` `Date`
(or `Date32` outside its range), `appendSysTime` `DateTime` for whole seconds
in its range, else `DateTime64(9)`, `appendUUID` `UUID`. `appendTyped` chooses
the type explicitly, and `appendValue` derives it from the D type
(`long[]` is `Array(Int64)`, a struct a named `Tuple`, and so on).
+/
final class DynamicColumn : Column
{
    /// The type name of the alternative that holds binary-encoded values in the V1 form.
    enum sharedVariantName = "SharedVariant";
    /// The most types a column holds (the server's limit for `max_types`).
    enum maxTypes = 254;

    /// The values, with one alternative per type.
    VariantColumn values;

    private string defaultTimezone;

    /++
    Creates an empty column.

    Params:
        name = column name.
        typeName = ClickHouse type name, e.g. `"Dynamic"` or `"Dynamic(max_types=8)"`.
        defaultTimezone = timezone for `DateTime` values without one (the server's).
    +/
    this(string name, string typeName, string defaultTimezone = null) @safe pure nothrow
    {
        super(name, typeName);
        this.defaultTimezone = defaultTimezone;
        values = new VariantColumn(name, "Variant()", null);
    }

    override @property size_t length() const @safe pure nothrow
    {
        return values.length;
    }

    /// The type of the value in `row` (as the server's `dynamicType()`), `null` for NULL, or
    /// `"SharedVariant"` for a value this client can't decode.
    string dynamicTypeName(size_t row) const @safe
    {
        return values.variantTypeName(row);
    }

    /// The type names of the alternatives, in the order of `values.variants`.
    @property string[] types() const @safe
    {
        string[] names;
        foreach (v; values.variants)
            names ~= v.typeName;
        return names;
    }

    /// The column of a new alternative of type `typeName`.
    private Column newAlternative(string typeName) const @safe
    {
        import clickhoused.types.factory : createColumn;

        if (typeName == sharedVariantName)
            return new StringColumn(name, sharedVariantName);
        return createColumn(name, typeName, defaultTimezone);
    }

    /++
    Reads the structure of the block: the V1 or V2 form (a Variant of the
    types plus `SharedVariant`) or the flattened form (the type list).
    +/
    override void readStatePrefix(BufferedReader reader) @safe
    {
        import std.algorithm.sorting : sort;
        import std.conv : to;

        const structureVersion = reader.readFixed!ulong();
        if (structureVersion != 1 && structureVersion != 2 && structureVersion != 3)
            throw new ProtocolException("Column '" ~ name ~ "' (" ~ typeName
                    ~ "): unsupported Dynamic serialization version " ~ structureVersion.to!string);
        if (structureVersion == 1)
            reader.readUVarInt(); // V1 also writes the number of types here
        const count = reader.readUVarInt();
        if (count > maxTypes)
            throw new ClientException("Column '" ~ name ~ "' (" ~ typeName ~ ") holds " ~ count.to!string
                    ~ " types; at most " ~ maxTypes.to!string ~ " are supported");
        string[] names;
        foreach (_; 0 .. count)
            names ~= reader.readString();
        flattened = structureVersion == 3;
        if (!flattened)
        {
            // The alternatives of the V1/V2 Variant are the types and SharedVariant, sorted by name
            names ~= sharedVariantName;
            sort(names);
        }
        Column[] columns;
        foreach (n; names)
            columns ~= newAlternative(n);
        values = new VariantColumn(name, "Variant()", columns);
        if (flattened)
            foreach (c; columns)
                c.readStatePrefix(reader);
        else
            values.readStatePrefix(reader);
    }

    private bool flattened; // the structure read last was the flattened form

    /// Reads the values of the block, in the form given by the prefix.
    override void readData(BufferedReader reader, size_t rows) @safe
    {
        import std.conv : to;

        if (!flattened)
            return values.readData(reader, rows);
        // Flattened: one index per row (UInt8, as there are fewer than 256 types; the type count means NULL),
        // then each type's values in order
        const count = values.variants.length;
        ubyte[] indexes;
        while (indexes.length < rows)
        {
            const start = indexes.length;
            const n = rows - start < readChunkRows ? rows - start : readChunkRows;
            indexes.length = start + n;
            reader.readExact(indexes[start .. $]);
        }
        foreach (ref i; indexes)
        {
            if (i == count)
                i = VariantColumn.nullDiscriminator;
            else if (i > count)
                throw new ProtocolException("Column '" ~ name ~ "' (" ~ typeName ~ "): invalid type index "
                        ~ i.to!string);
        }
        const counts = values.assignDiscriminators(indexes);
        foreach (i, v; values.variants)
            v.readData(reader, counts[i]);
    }

    /++
    The alternatives in the order of the V1 form: sorted by type name, with
    SharedVariant; the index of each in `values.variants`, or -1 for a
    SharedVariant the column doesn't have (it has no values).
    +/
    private ptrdiff_t[] sortedOrder() const @safe
    {
        import std.algorithm.sorting : sort;

        ptrdiff_t[] order;
        foreach (i; 0 .. values.variants.length)
            order ~= i;
        if (!hasShared())
            order ~= -1;
        string nameOf(ptrdiff_t i) @safe
        {
            return i < 0 ? sharedVariantName : values.variants[i].typeName;
        }

        sort!((a, b) => nameOf(a) < nameOf(b))(order);
        return order;
    }

    /// Whether the alternatives include SharedVariant.
    private bool hasShared() const @safe
    {
        foreach (v; values.variants)
            if (v.typeName == sharedVariantName)
                return true;
        return false;
    }

    /++
    Writes the structure in the V1 form: the type names, then the prefix of
    `Variant(types..., SharedVariant)` with the alternatives sorted by name.
    +/
    override void writeStatePrefix(BufferedWriter writer) const @safe
    {
        string[] names;
        foreach (i; sortedOrder())
            if (i >= 0 && values.variants[i].typeName != sharedVariantName)
                names ~= values.variants[i].typeName;
        writer.writeFixed!ulong(1);
        writer.writeUVarInt(names.length);
        writer.writeUVarInt(names.length);
        foreach (n; names)
            writer.writeString(n);
        writer.writeFixed!ulong(0); // the Variant's discriminators mode: basic
        // Prefixes in sorted order; a missing SharedVariant is a String, which has no prefix
        foreach (i; sortedOrder())
            if (i >= 0)
                values.variants[i].writeStatePrefix(writer);
    }

    /// Writes the values in the V1 form.
    override void writeData(BufferedWriter writer) const @safe
    {
        // The discriminators of the V1 Variant are the positions in the sorted order
        const order = sortedOrder();
        auto remap = new ubyte[values.variants.length];
        foreach (position, i; order)
            if (i >= 0)
                remap[i] = cast(ubyte) position;
        auto discriminators = new ubyte[values.length];
        foreach (row, d; values.discriminators)
            discriminators[row] = d == VariantColumn.nullDiscriminator ? d : remap[d];
        writer.writeBytes(discriminators);
        foreach (i; order)
            if (i >= 0)
                values.variants[i].writeData(writer); // a missing SharedVariant has no values
    }

    override @property bool isNullable() const @safe pure nothrow
    {
        return true;
    }

    override bool isNull(size_t row) const @safe
    {
        return values.isNull(row);
    }

    /// The column and position of the value in `row`.
    package(clickhoused) const(Column) held(size_t row, out size_t position) const @safe
    {
        import std.conv : to;

        if (values.isNull(row))
            throw new ClientException("Column '" ~ name ~ "', row " ~ row.to!string ~ ": value is NULL");
        auto column = values.variants[values.discriminators[row]];
        if (column.typeName == sharedVariantName)
            throw new ClientException("Column '" ~ name ~ "', row " ~ row.to!string ~ ": the value is stored "
                    ~ "binary-encoded (SharedVariant), which this client can't decode. The server is older than "
                    ~ "25.6, or output_format_native_use_flattened_dynamic_and_json_serialization is off");
        position = values.position(row);
        return column;
    }

    override long getLong(size_t row) const @safe
    {
        size_t p;
        return held(row, p).getLong(p);
    }

    override ulong getUlong(size_t row) const @safe
    {
        size_t p;
        return held(row, p).getUlong(p);
    }

    override double getDouble(size_t row) const @safe
    {
        size_t p;
        return held(row, p).getDouble(p);
    }

    override bool getBool(size_t row) const @safe
    {
        size_t p;
        return held(row, p).getBool(p);
    }

    /// The text of the value.
    override string getString(size_t row) const @safe
    {
        size_t p;
        return held(row, p).getString(p);
    }

    override const(ubyte)[] getBytes(size_t row) const @safe
    {
        size_t p;
        return held(row, p).getBytes(p);
    }

    override Date getDate(size_t row) const @safe
    {
        size_t p;
        return held(row, p).getDate(p);
    }

    override SysTime getSysTime(size_t row) const @safe
    {
        size_t p;
        return held(row, p).getSysTime(p);
    }

    override UUID getUUID(size_t row) const @safe
    {
        size_t p;
        return held(row, p).getUUID(p);
    }

    override Duration getDuration(size_t row) const @safe
    {
        size_t p;
        return held(row, p).getDuration(p);
    }

    /// `NULL`, or the value as its type writes it inside an array.
    override string getQuotedString(size_t row) const @safe
    {
        if (values.isNull(row))
            return "NULL";
        size_t p;
        return held(row, p).getQuotedString(p);
    }

    /// The value's `Variant`, or an empty one for NULL.
    override Variant getVariant(size_t row) const @safe
    {
        if (values.isNull(row))
            return Variant.init;
        size_t p;
        return held(row, p).getVariant(p);
    }

    override void truncate(size_t length) @safe
    {
        values.truncate(length);
    }

    /// Appends NULL, the default value of a Dynamic.
    override void appendDefault() @safe
    {
        values.appendNull();
    }

    override void appendNull() @safe
    {
        values.appendNull();
    }

    /++
    Appends a value of type `typeName` (as the server writes it, e.g.
    `"Array(Int64)"`): `append` must add exactly one value to the column it is
    given. The type is added to the column if it is new.

    Example: `column.appendTyped("Decimal(18, 2)", (c) { c.appendString("1.25"); });`
    +/
    void appendTyped(string typeName, scope void delegate(Column) @safe append) @safe
    {
        import std.conv : to;
        import clickhoused.types.parser : parseType;

        // The server orders the types by its canonical names, so the names must be canonical
        const canonical = typeName == sharedVariantName ? typeName : parseType(typeName).toString();
        foreach (i, v; values.variants)
            if (v.typeName == canonical)
                return values.appendTo(i, append);
        if (values.variants.length >= maxTypes + (hasShared() ? 1 : 0))
            throw new ClientException("Column '" ~ name ~ "' holds the maximum of " ~ maxTypes.to!string ~ " types");
        const index = values.variants.length;
        values.variants ~= newAlternative(canonical);
        scope (failure)
            values.variants.length = index; // a type that took no value is not added
        values.appendTo(index, append);
    }

    override void appendLong(long value) @safe
    {
        appendTyped("Int64", (c) => c.appendLong(value));
    }

    override void appendUlong(ulong value) @safe
    {
        appendTyped("UInt64", (c) => c.appendUlong(value));
    }

    override void appendDouble(double value) @safe
    {
        appendTyped("Float64", (c) => c.appendDouble(value));
    }

    override void appendBool(bool value) @safe
    {
        appendTyped("Bool", (c) => c.appendBool(value));
    }

    /// Appends a `String`.
    override void appendString(string value) @safe
    {
        appendTyped("String", (c) => c.appendString(value));
    }

    override void appendBytes(const(ubyte)[] value) @safe
    {
        appendTyped("String", (c) => c.appendBytes(value));
    }

    /// Appends a `Date`, or a `Date32` outside the range of `Date` (1970 to 2149).
    override void appendDate(Date value) @safe
    {
        const fits = value >= Date(1970, 1, 1) && value <= Date(2149, 6, 6);
        appendTyped(fits ? "Date" : "Date32", (c) => c.appendDate(value));
    }

    /// Appends a `DateTime` for whole seconds in its range (1970 to 2106), else a `DateTime64(9)`.
    override void appendSysTime(SysTime value) @safe
    {
        const seconds = value.toUnixTime!long;
        const whole = value.fracSecs == Duration.zero && seconds >= 0 && seconds <= uint.max;
        appendTyped(whole ? "DateTime" : "DateTime64(9)", (c) => c.appendSysTime(value));
    }

    override void appendUUID(UUID value) @safe
    {
        appendTyped("UUID", (c) => c.appendUUID(value));
    }

    /// A time span has no inferred type: use `appendTyped` with `Time` or `Time64(p)`.
    override void appendDuration(Duration value) @safe
    {
        throw new ClientException("Cannot store a Duration in column '" ~ name ~ "' (" ~ typeName
                ~ ") without a type; use appendTyped(\"Time64(7)\", ...)");
    }

    /++
    Appends an element of a text list (`[1, 'a']`): quoted text as `String`,
    `true`/`false` as `Bool`, numbers as `Int64`, `UInt64` or `Float64`.
    Other bare text (nested lists) has no inferred type and throws.
    +/
    package(clickhoused) void appendTextElement(string text, bool quoted) @safe
    {
        import std.conv : ConvException, to;

        if (quoted)
            return appendString(text);
        if (text == "true" || text == "false")
            return appendBool(text == "true");
        try
            return appendLong(text.to!long);
        catch (ConvException)
        {
        }
        try
            return appendUlong(text.to!ulong);
        catch (ConvException)
        {
        }
        try
            return appendDouble(text.to!double);
        catch (ConvException)
        {
        }
        throw new ClientException(
                "Cannot infer the type of '" ~ text ~ "' for column '" ~ name ~ "' ("
                ~ typeName ~ "); use appendTyped");
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        auto other = sameKind!DynamicColumn(source);
        if (other.values.isNull(row))
            return appendNull();
        const alternative = other.values.variants[other.values.discriminators[row]];
        const position = other.values.position(row);
        appendTyped(alternative.typeName, (c) => c.appendFrom(alternative, position));
    }
}

///
@system unittest
{
    import clickhoused.types.factory : createColumn;

    auto d = cast(DynamicColumn) createColumn("d", "Dynamic");
    d.appendLong(1);
    d.appendString("ab");
    d.appendNull();
    d.appendTyped("Array(UInt8)", (c) { c.appendString("[1, 2]"); });
    assert(d.dynamicTypeName(0) == "Int64" && d.dynamicTypeName(1) == "String" && d.isNull(2));
    assert(d.getString(3) == "[1,2]" && d.getVariant(0).get!long == 1);
    assert(d.types == ["Int64", "String", "Array(UInt8)"]);
}

// Golden bytes from a 26.11 server for `Dynamic(max_types=2)` values 1::Int64, 'ab', NULL, 2.5, a Date and
// [1,2]::Array(UInt8): the V1 form (Float64, Date and Array in SharedVariant) and the flattened form
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.io.mock : MockTransport;
    import clickhoused.types.factory : createColumn;

    DynamicColumn read(const(ubyte)[] bytes, size_t rows)
    {
        auto t = new MockTransport;
        t.feed(bytes);
        auto reader = new BufferedReader(t);
        auto d = cast(DynamicColumn) createColumn("d", "Dynamic(max_types=2)");
        d.readStatePrefix(reader);
        d.readData(reader, rows);
        assert(t.remaining == 0);
        return d;
    }

    const ubyte[] v1 = [
        1, 0, 0, 0, 0, 0, 0, 0, 2, 2, 5, 'I', 'n', 't', '6', '4', 6, 'S', 't', 'r', 'i', 'n', 'g', // structure
        0, 0, 0, 0, 0, 0, 0, 0, // Variant mode
        0, 2, 0xff, 1, 1, 1, // discriminators: Int64, String, NULL, SharedVariant x3
        1, 0, 0, 0, 0, 0, 0, 0, // Int64 1
        9, 0x0e, 0, 0, 0, 0, 0, 0, 4, 0x40, 3, 0x0f, 0x57, 0x47, 5, 0x1e, 1, 2, 1, 2, // SharedVariant
        2, 'a',
        'b' // String
    ];
    auto d = read(v1, 6);
    assert(d.getLong(0) == 1 && d.getString(1) == "ab" && d.isNull(2));
    assert(d.dynamicTypeName(3) == DynamicColumn.sharedVariantName);
    assertThrown!ClientException(d.getString(3));

    const ubyte[] flat = [
        3, 0, 0, 0, 0, 0, 0, 0, 5, 5, 'I', 'n', 't', '6', '4', 6, 'S', 't', 'r', 'i', 'n', 'g', 12,
        'A', 'r', 'r',
        'a', 'y', '(', 'U', 'I', 'n', 't', '8', ')', 4, 'D', 'a', 't', 'e', 7, 'F', 'l', 'o', 'a', 't',
        '6', '4',
        0, 1, 5, 4, 3, 2, // indexes; 5 = NULL
        1, 0, 0, 0, 0, 0, 0, 0, 2, 'a', 'b', 2, 0, 0, 0, 0, 0, 0, 0, 1, 2, 0x57, 0x47, 0, 0, 0, 0, 0,
        0, 4, 0x40
    ];
    d = read(flat, 6);
    string[] texts;
    foreach (row; 0 .. 6)
        texts ~= d.isNull(row) ? "NULL" : d.dynamicTypeName(row) ~ ":" ~ d.getString(row);
    assert(texts == [
        "Int64:1", "String:ab", "NULL", "Float64:2.5", "Date:2020-01-02", "Array(UInt8):[1,2]"
    ], texts[0]);

    // Writing gives the V1 form, sorted by type name with an empty SharedVariant; reading it back gives the same
    auto w = new MockTransport;
    auto writer = new BufferedWriter(w);
    d.writeStatePrefix(writer);
    d.writeData(writer);
    writer.flush();
    auto back = read(w.written, 6);
    foreach (row; 0 .. 6)
    {
        assert(back.isNull(row) == d.isNull(row));
        if (!d.isNull(row))
            assert(back.dynamicTypeName(row) == d.dynamicTypeName(row) && back.getString(row) == d.getString(row));
    }
    assert(back.types == [
        "Array(UInt8)", "Date", "Float64", "Int64", DynamicColumn.sharedVariantName, "String"
    ]);

    // Bad input
    auto bad = new MockTransport;
    bad.feed(cast(const(ubyte)[])[9, 0, 0, 0, 0, 0, 0, 0]);
    assertThrown!ProtocolException(d.readStatePrefix(new BufferedReader(bad)));
}

@safe unittest
{
    import core.time : seconds;
    import std.datetime.timezone : UTC;
    import std.exception : assertThrown;
    import clickhoused.types.factory : createColumn;

    // Appends infer the types as the server does for inserted text
    auto d = cast(DynamicColumn) createColumn("d", "Dynamic", "UTC");
    d.appendUlong(5);
    d.appendDouble(2.5);
    d.appendBool(true);
    d.appendDate(Date(2020, 1, 2));
    d.appendDate(Date(1900, 1, 1));
    d.appendSysTime(SysTime.fromUnixTime(86_400, UTC()));
    d.appendSysTime(SysTime.fromUnixTime(1, UTC()) + 5.seconds / 10);
    string[] kinds;
    foreach (row; 0 .. d.length)
        kinds ~= d.dynamicTypeName(row);
    assert(kinds == ["UInt64", "Float64", "Bool", "Date", "Date32", "DateTime", "DateTime64(9)"]);
    assert(d.getString(5) == "1970-01-02 00:00:00" && d.getString(6) == "1970-01-01 00:00:01.500000000");
    assertThrown!ClientException(d.appendDuration(1.seconds));
    assertThrown!ClientException(d.appendTyped("UInt8", (c) { c.appendLong(300); }));
    assert(d.types.length == 7 && d.length == 7); // the failed UInt8 left no type behind

    // Text lists
    auto a = createColumn("a", "Array(Dynamic)");
    a.appendString("[1, 'x', NULL, 2.5, true]");
    assert(a.getString(0) == "[1,'x',NULL,2.5,true]");
    assertThrown!ClientException(a.appendString("[[1]]"));

    // appendFrom copies the value with its type; truncate keeps the types
    auto copy = cast(DynamicColumn) createColumn("d", "Dynamic");
    copy.appendFrom(d, 4);
    copy.appendFrom((cast(clickhoused.types.array.ArrayColumn) a).elements, 2);
    assert(copy.dynamicTypeName(0) == "Date32" && copy.isNull(1));
}
