/++
`UUID`, `Enum8`, `Enum16`, `Nullable(T)` and `Nothing` columns.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.misc;

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

    override void readData(BufferedReader reader, size_t rows) @safe
    {
        data = null;
        data.reserve(rows < readChunkRows ? rows : readChunkRows);
        ubyte[16] wire;
        foreach (i; 0 .. rows)
        {
            reader.readExact(wire[]);
            data ~= UUID(swapHalves(wire));
        }
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        foreach (ref v; data)
        {
            const wire = swapHalves(v.data);
            writer.writeBytes(wire[]);
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

    private static ubyte[16] swapHalves(const ubyte[16] bytes) @safe pure nothrow @nogc
    {
        ubyte[16] r;
        foreach (i; 0 .. 8)
        {
            r[i] = bytes[7 - i];
            r[8 + i] = bytes[15 - i];
        }
        return r;
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
        nulls = null;
        ubyte[] chunk;
        while (nulls.length < rows)
        {
            const count = rows - nulls.length < readChunkRows ? rows - nulls.length : readChunkRows;
            chunk.length = count;
            reader.readExact(chunk);
            foreach (b; chunk)
                nulls ~= b != 0;
        }
        nested.readData(reader, rows);
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        if (nested.length != nulls.length)
            throw new ClientException("Column '" ~ name ~ "': NULL flags and values differ in length");
        foreach (n; nulls)
            writer.writeByte(n ? 1 : 0);
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
