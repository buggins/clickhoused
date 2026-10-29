/++
Columns: the typed data of one column of a `clickhoused.block.Block`.

Each ClickHouse type is represented by a `Column` subclass that owns the
decoded values as a D array. Use `createColumn` to build the right subclass
from a type name sent by the server.

This version supports:
$(UL
    $(LI `UInt8`…`UInt64`, `Int8`…`Int64`, `Float32`, `Float64`;)
    $(LI `Bool`;)
    $(LI `String`, `FixedString(N)`;)
    $(LI `Date`, `DateTime`, `Enum8`, `Enum16`, as raw stored values.
        Typed access to them comes in a later version.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.column;

import clickhoused.exception : ClientException, ProtocolException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter, fromLittleEndian, isFixedWireType;
import clickhoused.types.parser : TypeNode, TypeArgKind, parseType;

/// Rows decoded per step when reading a column, so memory grows only with
/// data actually received rather than with a row count claimed by the server.
private enum size_t readChunkRows = 64 * 1024;

/// Base class of all columns.
abstract class Column
{
    /// Column name.
    string name;
    /// Type name as sent by the server, e.g. `"Nullable(String)"`.
    string typeName;

    /++
    Creates a column.

    Params:
        name = column name.
        typeName = ClickHouse type name.
    +/
    this(string name, string typeName) @safe pure nothrow
    {
        this.name = name;
        this.typeName = typeName;
    }

    /// Number of rows.
    abstract @property size_t length() const @safe pure nothrow;

    /++
    Replaces the contents with `rows` values read from the native format.

    Throws: `clickhoused.exception.ConnectionException` or
    `clickhoused.exception.ProtocolException` on bad input.
    +/
    abstract void readData(BufferedReader reader, size_t rows) @safe;

    /// Writes all values in the native format.
    abstract void writeData(BufferedWriter writer) @safe;
}

/++
Column of fixed-size numbers stored as `T[]`.

Also used for the raw storage of `Date` (`ushort` days since 1970-01-01),
`DateTime` (`uint` seconds since the epoch), `Enum8` (`byte`) and
`Enum16` (`short`).
+/
final class NumericColumn(T) : Column if (isFixedWireType!T && !is(T == bool))
{
    /// Column values.
    T[] data;

    /// Creates an empty column.
    this(string name, string typeName) @safe pure nothrow
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
        while (data.length < rows)
        {
            const start = data.length;
            const count = rows - start < readChunkRows ? rows - start : readChunkRows;
            data.length = start + count;
            readValues(reader, data[start .. $]);
        }
    }

    override void writeData(BufferedWriter writer) @safe
    {
        version (LittleEndian)
            writer.writeBytes((() @trusted => cast(const(ubyte)[]) data)()); // same memory layout as the wire
        else
            foreach (v; data)
                writer.writeFixed(v);
    }

    private static void readValues(BufferedReader reader, T[] values) @safe
    {
        version (LittleEndian)
            reader.readExact((() @trusted => cast(ubyte[]) values)()); // same memory layout as the wire
        else
        {
            foreach (ref v; values)
                v = reader.readFixed!T();
        }
    }
}

/// `UInt8` column.
alias UInt8Column = NumericColumn!ubyte;
/// `UInt16` column.
alias UInt16Column = NumericColumn!ushort;
/// `UInt32` column.
alias UInt32Column = NumericColumn!uint;
/// `UInt64` column.
alias UInt64Column = NumericColumn!ulong;
/// `Int8` column.
alias Int8Column = NumericColumn!byte;
/// `Int16` column.
alias Int16Column = NumericColumn!short;
/// `Int32` column.
alias Int32Column = NumericColumn!int;
/// `Int64` column.
alias Int64Column = NumericColumn!long;
/// `Float32` column.
alias Float32Column = NumericColumn!float;
/// `Float64` column.
alias Float64Column = NumericColumn!double;

/// `Bool` column (one byte per value on the wire).
final class BoolColumn : Column
{
    /// Column values.
    bool[] data;

    /// Creates an empty column.
    this(string name, string typeName = "Bool") @safe pure nothrow
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
        ubyte[] chunk;
        while (data.length < rows)
        {
            const count = rows - data.length < readChunkRows ? rows - data.length : readChunkRows;
            chunk.length = count;
            reader.readExact(chunk);
            foreach (b; chunk)
                data ~= b != 0;
        }
    }

    override void writeData(BufferedWriter writer) @safe
    {
        foreach (v; data)
            writer.writeByte(v ? 1 : 0);
    }
}

/// `String` column. Values are arbitrary bytes, not necessarily valid UTF-8.
final class StringColumn : Column
{
    /// Column values.
    string[] data;

    /// Creates an empty column.
    this(string name, string typeName = "String") @safe pure nothrow
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
        foreach (i; 0 .. rows)
            data ~= reader.readString();
    }

    override void writeData(BufferedWriter writer) @safe
    {
        foreach (v; data)
            writer.writeString(v);
    }
}

/// `FixedString(N)` column: every value is exactly `width` bytes, padded with zero bytes.
final class FixedStringColumn : Column
{
    /// Value size in bytes (the `N` in `FixedString(N)`).
    immutable size_t width;
    /// All values, concatenated: value `i` is `bytes[i * width .. (i + 1) * width]`.
    ubyte[] bytes;

    /++
    Creates an empty column.

    Params:
        name = column name.
        width = value size in bytes.
        typeName = ClickHouse type name.
    +/
    this(string name, size_t width, string typeName) @safe pure nothrow
    {
        super(name, typeName);
        this.width = width;
    }

    override @property size_t length() const @safe pure nothrow
    {
        return width ? bytes.length / width : 0;
    }

    /// Returns value `row` as raw bytes, including padding.
    const(ubyte)[] opIndex(size_t row) const @safe pure nothrow
    {
        return bytes[row * width .. (row + 1) * width];
    }

    /// Returns value `row` as a string with trailing zero bytes removed.
    string asString(size_t row) const @safe pure
    {
        auto value = this[row];
        size_t n = value.length;
        while (n > 0 && value[n - 1] == 0)
            n--;
        return cast(string) value[0 .. n].idup;
    }

    override void readData(BufferedReader reader, size_t rows) @safe
    {
        bytes = null;
        size_t done;
        while (done < rows)
        {
            const count = rows - done < readChunkRows ? rows - done : readChunkRows;
            const start = bytes.length;
            bytes.length = start + count * width;
            reader.readExact(bytes[start .. $]);
            done += count;
        }
    }

    override void writeData(BufferedWriter writer) @safe
    {
        writer.writeBytes(bytes);
    }
}

/++
Creates an empty column for the ClickHouse type `typeName`.

Throws:
    `ClientException` if the type is not supported by this version of clickhoused;
    `ProtocolException` if `typeName` is not a valid type name.
+/
Column createColumn(string name, string typeName) @safe
{
    import std.conv : to;

    const type = parseType(typeName);

    Column numeric(T)()
    {
        return new NumericColumn!T(name, typeName);
    }

    switch (type.name)
    {
    case "UInt8":
        return numeric!ubyte;
    case "UInt16":
        return numeric!ushort;
    case "UInt32":
        return numeric!uint;
    case "UInt64":
        return numeric!ulong;
    case "Int8":
        return numeric!byte;
    case "Int16":
        return numeric!short;
    case "Int32":
        return numeric!int;
    case "Int64":
        return numeric!long;
    case "Float32":
        return numeric!float;
    case "Float64":
        return numeric!double;
    case "Bool":
        return new BoolColumn(name, typeName);
    case "String":
        return new StringColumn(name, typeName);
    case "FixedString":
        if (type.args.length != 1 || type.args[0].kind != TypeArgKind.number || type.args[0].number <= 0)
            throw new ProtocolException("Invalid type name '" ~ typeName ~ "'");
        return new FixedStringColumn(name, type.args[0].number.to!size_t, typeName);
    case "Date":
        return numeric!ushort;
    case "DateTime":
        return numeric!uint;
    case "Enum8":
        return numeric!byte;
    case "Enum16":
        return numeric!short;
    default:
        throw new ClientException("Unsupported column type '" ~ typeName ~ "' (column '" ~ name ~ "')");
    }
}

///
@safe unittest
{
    const c = createColumn("n", "UInt32");
    assert(cast(const UInt32Column) c !is null);
    assert(c.typeName == "UInt32");

    auto f = cast(FixedStringColumn) createColumn("code", "FixedString(3)");
    assert(f.width == 3);
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.io.mock : MockTransport;

    // Native-format round trip for every supported column kind
    auto t = new MockTransport;
    auto w = new BufferedWriter(t);

    auto ints = new Int64Column("i", "Int64");
    ints.data = [long.min, -1, 0, long.max];
    auto floats = new Float64Column("f", "Float64");
    floats.data = [0.5, -2.25, double.infinity, 0];
    auto flags = new BoolColumn("b");
    flags.data = [true, false, true, true];
    auto strings = new StringColumn("s");
    strings.data = ["", "abc", "Ünïcødé", "\0x"];
    auto fixed = new FixedStringColumn("fs", 2, "FixedString(2)");
    fixed.bytes = ['a', 0, 'b', 'c', 0, 0, 'z', 'z'];

    foreach (Column c; [ints, floats, flags, strings, fixed])
        c.writeData(w);
    w.flush();

    t.feed(t.written);
    auto r = new BufferedReader(t);
    auto columns = [
        createColumn("i", "Int64"), createColumn("f", "Float64"), createColumn("b", "Bool"),
        createColumn("s", "String"), createColumn("fs", "FixedString(2)"),
    ];
    foreach (c; columns)
        c.readData(r, 4);

    assert((cast(Int64Column) columns[0]).data == ints.data);
    assert((cast(Float64Column) columns[1]).data == floats.data);
    assert((cast(BoolColumn) columns[2]).data == flags.data);
    assert((cast(StringColumn) columns[3]).data == strings.data);
    auto fs = cast(FixedStringColumn) columns[4];
    assert(fs.length == 4 && fs.asString(0) == "a" && fs.asString(1) == "bc" && fs.asString(2) == "");

    assertThrown!ClientException(createColumn("x", "Array(UInt8)"));
    assertThrown!ProtocolException(createColumn("x", "FixedString(0)"));
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.exception : ConnectionException;
    import clickhoused.io.mock : MockTransport;

    // A row count far beyond the data received fails cleanly, without a huge allocation
    auto t = new MockTransport;
    t.feed([1, 2, 3, 4]);
    auto c = new UInt64Column("x", "UInt64");
    assertThrown!ConnectionException(c.readData(new BufferedReader(t), size_t.max / 16));
}
