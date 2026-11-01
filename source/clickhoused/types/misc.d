/++
`UUID`, `Enum8`, `Enum16`, `Nullable(T)` and `Nothing` columns.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.misc;

import core.time : Duration;
import std.datetime.date : Date;
import std.datetime.systime : SysTime;
import std.uuid : UUID;
import std.variant : Variant;

import clickhoused.exception : ClientException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column;

/++
`UUID` column.

On the wire each 8-byte half of the UUID is byte-reversed (two little-endian
64-bit integers); `data` holds them in the usual order.
+/
final class UUIDColumn : Column
{
    /// Column values.
    UUID[] data;

    /// Creates an empty column.
    this(string name, string typeName = "UUID") @safe pure nothrow
    {
        super(name, typeName);
    }

    override @property size_t length() const @safe pure nothrow
    {
        return data.length;
    }

    /// Reads the values in one piece, then converts their byte order in place.
    override void readData(BufferedReader reader, size_t rows) @safe
    {
        data = null;
        while (data.length < rows)
        {
            const start = data.length;
            data = growUninitialized(data, growRows(start, rows));
            auto bytes = bytesOf(data[start .. $]); // a UUID is its 16 bytes
            reader.readExact(bytes);
            reverseHalves(bytes);
        }
    }

    /// Writes the values in chunks, converting their byte order on the way.
    override void writeData(BufferedWriter writer) const @safe
    {
        enum chunkValues = 4096;
        ubyte[] buffer = new ubyte[16 * (data.length < chunkValues ? data.length : chunkValues)];
        for (size_t i = 0; i < data.length; i += chunkValues)
        {
            const values = data[i .. i + chunkValues < data.length ? i + chunkValues : data.length];
            auto bytes = buffer[0 .. 16 * values.length];
            bytes[] = bytesOf(values)[];
            reverseHalves(bytes);
            writer.writeBytes(bytes);
        }
    }

    override UUID getUUID(size_t row) const @safe
    {
        return data[row];
    }

    /// The UUID in the canonical `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` form.
    /// Quoted inside arrays.
    override protected @property bool quotedInText() const @safe pure nothrow
    {
        return true;
    }

    override string getString(size_t row) const @safe
    {
        return data[row].toString();
    }

    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(data[row]);
    }

    override void appendDefault() @safe
    {
        data ~= UUID.init;
    }

    override void truncate(size_t length) @safe
    {
        if (length < data.length)
            data.length = length;
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        data ~= sameKind!UUIDColumn(source).data[row];
    }

    override void appendUUID(UUID value) @safe
    {
        data ~= value;
    }

    /// Parses the canonical form.
    override void appendString(string value) @safe
    {
        import std.uuid : UUIDParsingException;

        try
            data ~= UUID(value);
        catch (UUIDParsingException)
            throw appendError("string", value);
    }

    /++
    Converts between the wire form (two little-endian 64-bit halves) and the
    byte order of `UUID` (big-endian), for whole values: reverses each group
    of 8 bytes.
    +/
    private static void reverseHalves(ubyte[] bytes) @trusted pure nothrow @nogc
    {
        import core.bitop : bswap;
        import core.stdc.string : memcpy;

        assert(bytes.length % 8 == 0);
        for (size_t i = 0; i < bytes.length; i += 8) // within `bytes`: its length is a multiple of 8
        {
            ulong v = void;
            memcpy(&v, bytes.ptr + i, 8);
            v = bswap(v);
            memcpy(bytes.ptr + i, &v, 8);
        }
    }
}

///
@safe unittest
{
    import clickhoused.io.mock : MockTransport;

    // Wire layout checked against the server: each half is byte-reversed
    auto t = new MockTransport;
    t.feed([
        0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00, 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA, 0x99, 0x88
    ]);
    auto c = new UUIDColumn("id");
    c.readData(new BufferedReader(t), 1);
    assert(c.getString(0) == "00112233-4455-6677-8899-aabbccddeeff");

    auto w = new BufferedWriter(t);
    c.writeData(w);
    w.flush();
    assert(t.written[0] == 0x77 && t.written[15] == 0x88);
}

/++
`Enum8` / `Enum16` column: values stored as `byte` / `short`, with the
label of each value taken from the type.
+/
final class EnumColumn(T) : FixedColumn!T if (is(T == byte) || is(T == short))
{
    /// Label of each value, from the type definition.
    string[T] labels;
    /// Value of each label, from the type definition.
    T[string] values;

    /++
    Creates an empty column.

    Params:
        name = column name.
        typeName = ClickHouse type name.
        elements = the enum's labels and values.
    +/
    this(string name, string typeName, const T[string] elements) @safe pure
    {
        super(name, typeName);
        foreach (label, value; elements)
        {
            labels[value] = label;
            values[label] = value;
        }
    }

    /++
    The label of the value in `row`.

    Throws: `ClientException` if the value has no label (the server never sends such values).
    +/
    string label(size_t row) const @safe
    {
        if (auto p = data[row] in labels)
            return *p;
        throw conversionError(row, "enum label");
    }

    /// The label.
    /// Quoted inside arrays.
    override protected @property bool quotedInText() const @safe pure nothrow
    {
        return true;
    }

    override string getString(size_t row) const @safe
    {
        return label(row);
    }

    /// The numeric value.
    override long getLong(size_t row) const @safe
    {
        return data[row];
    }

    /// The label.
    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(label(row));
    }

    /// Appends the smallest defined value.
    override void appendDefault() @safe
    {
        T smallest = T.max;
        foreach (v; labels.byKey)
            if (v < smallest)
                smallest = v;
        data ~= labels.length ? smallest : 0;
    }

    /// Appends the value of the label `value`.
    override void appendString(string value) @safe
    {
        if (auto v = value in values)
            data ~= *v;
        else
            throw appendError("string", value);
    }

    /// Appends a numeric value; it must be one of the defined values.
    override void appendLong(long value) @safe
    {
        if (value < T.min || value > T.max || (cast(T) value) !in labels)
            throw appendError("long", value);
        data ~= cast(T) value;
    }
}

/// `Enum8` column.
alias Enum8Column = EnumColumn!byte;
/// `Enum16` column.
alias Enum16Column = EnumColumn!short;

///
@safe unittest
{
    auto c = new Enum8Column("e", "Enum8('a' = 1, 'b' = 2)", ["a": 1, "b": 2]);
    c.data = [2, 1];
    assert(c.label(0) == "b");
    assert(c.getLong(1) == 1);
    assert(c.values["a"] == 1);
}

/++
`Nullable(T)` column: a NULL flag per row plus a column of the nested type.

The nested column has a value for every row; NULL rows hold the type's
default value there.
+/
final class NullableColumn : Column
{
    /// NULL flag of each row.
    bool[] nulls;
    /// Values; meaningful only where `nulls` is false.
    Column nested;

    /++
    Creates an empty column.

    Params:
        name = column name.
        typeName = ClickHouse type name.
        nested = empty column of the nested type.
    +/
    this(string name, string typeName, Column nested) @safe pure nothrow
    {
        super(name, typeName);
        this.nested = nested;
    }

    override @property size_t length() const @safe pure nothrow
    {
        return nulls.length;
    }

    override void readData(BufferedReader reader, size_t rows) @safe
    {
        nulls = readFlags(reader, rows);
        nested.readData(reader, rows);
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        if (nested.length != nulls.length)
            throw new ClientException("Column '" ~ name ~ "': NULL flags and values differ in length");
        writer.writeBytes(bytesOf(nulls)); // a bool is one byte holding 0 or 1
        nested.writeData(writer);
    }

    override @property bool isNullable() const @safe pure nothrow
    {
        return true;
    }

    override bool isNull(size_t row) const @safe
    {
        return nulls[row];
    }

    override long getLong(size_t row) const @safe
    {
        checkNotNull(row);
        return nested.getLong(row);
    }

    override ulong getUlong(size_t row) const @safe
    {
        checkNotNull(row);
        return nested.getUlong(row);
    }

    override double getDouble(size_t row) const @safe
    {
        checkNotNull(row);
        return nested.getDouble(row);
    }

    override bool getBool(size_t row) const @safe
    {
        checkNotNull(row);
        return nested.getBool(row);
    }

    override string getString(size_t row) const @safe
    {
        checkNotNull(row);
        return nested.getString(row);
    }

    override const(ubyte)[] getBytes(size_t row) const @safe
    {
        checkNotNull(row);
        return nested.getBytes(row);
    }

    override Date getDate(size_t row) const @safe
    {
        checkNotNull(row);
        return nested.getDate(row);
    }

    override SysTime getSysTime(size_t row) const @safe
    {
        checkNotNull(row);
        return nested.getSysTime(row);
    }

    override UUID getUUID(size_t row) const @safe
    {
        checkNotNull(row);
        return nested.getUUID(row);
    }

    override Duration getDuration(size_t row) const @safe
    {
        checkNotNull(row);
        return nested.getDuration(row);
    }

    /// `NULL`, or the quoted nested value.
    override string getQuotedString(size_t row) const @safe
    {
        return nulls[row] ? "NULL" : nested.getQuotedString(row);
    }

    /// The nested value, or an empty `Variant` for NULL.
    override Variant getVariant(size_t row) const @safe
    {
        return nulls[row] ? Variant.init : nested.getVariant(row);
    }

    /// Appends a NULL.
    override void appendDefault() @safe
    {
        appendNull();
    }

    override void truncate(size_t length) @safe
    {
        if (length < nulls.length)
            nulls.length = length;
        nested.truncate(length);
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        auto other = sameKind!NullableColumn(source);
        nested.appendFrom(other.nested, row);
        nulls ~= other.nulls[row];
    }

    override void readStatePrefix(BufferedReader reader) @safe
    {
        nested.readStatePrefix(reader);
    }

    override void writeStatePrefix(BufferedWriter writer) const @safe
    {
        nested.writeStatePrefix(writer);
    }

    override void appendNull() @safe
    {
        nested.appendDefault();
        nulls ~= true;
    }

    override void appendLong(long value) @safe
    {
        nested.appendLong(value);
        nulls ~= false;
    }

    override void appendUlong(ulong value) @safe
    {
        nested.appendUlong(value);
        nulls ~= false;
    }

    override void appendDouble(double value) @safe
    {
        nested.appendDouble(value);
        nulls ~= false;
    }

    override void appendBool(bool value) @safe
    {
        nested.appendBool(value);
        nulls ~= false;
    }

    override void appendString(string value) @safe
    {
        nested.appendString(value);
        nulls ~= false;
    }

    override void appendBytes(const(ubyte)[] value) @safe
    {
        nested.appendBytes(value);
        nulls ~= false;
    }

    override void appendDate(Date value) @safe
    {
        nested.appendDate(value);
        nulls ~= false;
    }

    override void appendSysTime(SysTime value) @safe
    {
        nested.appendSysTime(value);
        nulls ~= false;
    }

    override void appendUUID(UUID value) @safe
    {
        nested.appendUUID(value);
        nulls ~= false;
    }

    override void appendDuration(Duration value) @safe
    {
        nested.appendDuration(value);
        nulls ~= false;
    }

    private void checkNotNull(size_t row) const @safe
    {
        import std.conv : to;

        if (nulls[row])
            throw new ClientException("Column '" ~ name ~ "', row " ~ row.to!string ~ ": value is NULL");
    }
}

///
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.types.numeric : UInt32Column;

    auto values = new UInt32Column("n", "UInt32");
    values.data = [5, 0];
    auto c = new NullableColumn("n", "Nullable(UInt32)", values);
    c.nulls = [false, true];

    assert(c.getLong(0) == 5);
    assert(c.isNull(1));
    assert(!c.getVariant(1).hasValue);
    assertThrown!ClientException(c.getLong(1));
}

/// `Nothing` column: the type of a bare `NULL`, found only inside `Nullable(Nothing)`.
final class NothingColumn : Column
{
    /// Number of rows.
    size_t rows;

    /// Creates an empty column.
    this(string name, string typeName = "Nothing") @safe pure nothrow
    {
        super(name, typeName);
    }

    override @property size_t length() const @safe pure nothrow
    {
        return rows;
    }

    override void readData(BufferedReader reader, size_t rows) @safe
    {
        // One placeholder byte per row; read in chunks to bound memory
        ubyte[readChunkRows] skip;
        size_t left = rows;
        while (left)
        {
            const n = left < skip.length ? left : skip.length;
            reader.readExact(skip[0 .. n]);
            left -= n;
        }
        this.rows = rows;
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        foreach (i; 0 .. rows)
            writer.writeByte('0');
    }

    /// Always `"NULL"`.
    override string getString(size_t row) const @safe
    {
        return "NULL";
    }

    /// Always an empty `Variant`.
    override Variant getVariant(size_t row) const @safe
    {
        return Variant.init;
    }

    override void appendDefault() @safe
    {
        rows++;
    }

    override void truncate(size_t length) @safe
    {
        if (length < rows)
            rows = length;
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        sameKind!NothingColumn(source);
        rows++;
    }

    override void appendNull() @safe
    {
        rows++;
    }
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.types.numeric : UInt8Column;

    // Appending to UUID, Enum and Nullable columns
    auto id = new UUIDColumn("id");
    id.appendString("00112233-4455-6677-8899-aabbccddeeff");
    id.appendDefault();
    assert(id.getString(0) == "00112233-4455-6677-8899-aabbccddeeff" && id.data[1] == UUID.init);
    assertThrown!ClientException(id.appendString("nope"));

    auto e = new Enum8Column("e", "Enum8('a' = 5, 'b' = -3)", ["a": 5, "b": -3]);
    e.appendString("a");
    e.appendLong(-3);
    e.appendDefault();
    assert(e.data == [5, -3, -3]);
    assertThrown!ClientException(e.appendString("c"));
    assertThrown!ClientException(e.appendLong(4));

    auto n = new NullableColumn("n", "Nullable(UInt8)", new UInt8Column("n", "UInt8"));
    n.appendLong(7);
    n.appendNull();
    assert(n.nulls == [false, true] && (cast(UInt8Column) n.nested).data == [7, 0]);
    assertThrown!ClientException(n.appendLong(300));
    assert(n.length == 2); // a failed append leaves the column unchanged
}

@safe unittest
{
    import std.uuid : randomUUID;
    import clickhoused.io.mock : MockTransport;
    import clickhoused.types.factory : createColumn;
    import clickhoused.types.numeric : BoolColumn, Int8Column;

    // Flags read in one piece: any non-zero byte is true, and is written back as 1
    auto t = new MockTransport;
    t.feed(cast(const(ubyte)[])[0, 1, 2, 255, 0, 7, 8, 9]);
    auto r = new BufferedReader(t);
    auto b = new BoolColumn("b");
    b.readData(r, 4);
    assert(b.data == [false, true, true, true]);
    auto n = cast(NullableColumn) createColumn("n", "Nullable(Int8)");
    n.readData(r, 2);
    assert(n.nulls == [false, true] && (cast(Int8Column) n.nested).data == [8, 9]);
    auto w = new MockTransport;
    auto writer = new BufferedWriter(w);
    b.writeData(writer);
    n.writeData(writer);
    writer.flush();
    assert(w.written == [0, 1, 1, 1, 0, 1, 8, 9]);

    // UUIDs over several write chunks keep their values and byte order
    auto u = new UUIDColumn("u");
    foreach (i; 0 .. 10_000)
        u.data ~= randomUUID();
    u.data ~= UUID("00112233-4455-6677-8899-aabbccddeeff");
    auto ut = new MockTransport;
    auto uw = new BufferedWriter(ut);
    u.writeData(uw);
    uw.flush();
    assert(ut.written[$ - 16 .. $] == [
        0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00, 0xff, 0xee, 0xdd, 0xcc, 0xbb,
        0xaa, 0x99, 0x88
    ]);
    ut.feed(ut.written);
    auto back = new UUIDColumn("u");
    back.readData(new BufferedReader(ut), u.data.length);
    assert(back.data == u.data);
}
