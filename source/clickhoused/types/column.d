/++
Base classes of columns: the typed data of one column of a
`clickhoused.block.Block`.

Every ClickHouse type is represented by a `Column` subclass that owns the
decoded values as a D array (e.g. `UInt64Column.data` is a `ulong[]`). For
generic code, every column also offers per-cell getters with conversions:
`getLong`, `getString`, `getSysTime`, `isNull`, `getVariant` and so on.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.column;

import std.datetime.date : Date;
import std.datetime.systime : SysTime;
import std.uuid : UUID;
import std.variant : Variant;

import clickhoused.exception : ClientException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter, isFixedWireType;

/// Rows decoded per step when reading a column, so memory grows only with
/// data actually received rather than with a row count claimed by the server.
package enum size_t readChunkRows = 64 * 1024;

/++
Base class of all columns.

The typed getters convert the value of one cell. Each column type supports the
conversions that make sense for it; the others throw `ClientException`. Reading
a NULL cell of a `Nullable` column with any getter except `isNull` and
`getVariant` throws `ClientException` too.
+/
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
    abstract void writeData(BufferedWriter writer) const @safe;

    /// Whether the column can contain NULLs (its type is `Nullable(...)`).
    @property bool isNullable() const @safe pure nothrow
    {
        return false;
    }

    /// Whether the value in `row` is NULL.
    bool isNull(size_t row) const @safe
    {
        assert(row < length, "row out of range");
        return false;
    }

    /// The value in `row` as a signed integer.
    long getLong(size_t row) const @safe
    {
        throw conversionError(row, "long");
    }

    /// The value in `row` as an unsigned integer.
    ulong getUlong(size_t row) const @safe
    {
        throw conversionError(row, "ulong");
    }

    /// The value in `row` as a floating-point number.
    double getDouble(size_t row) const @safe
    {
        throw conversionError(row, "double");
    }

    /// The value in `row` as a boolean.
    bool getBool(size_t row) const @safe
    {
        throw conversionError(row, "bool");
    }

    /// The value in `row` as text, formatted as ClickHouse formats it.
    abstract string getString(size_t row) const @safe;

    /// The value in `row` as raw bytes (for `String` and `FixedString`).
    const(ubyte)[] getBytes(size_t row) const @safe
    {
        throw conversionError(row, "bytes");
    }

    /// The value in `row` as a calendar date.
    Date getDate(size_t row) const @safe
    {
        throw conversionError(row, "Date");
    }

    /// The value in `row` as a point in time.
    SysTime getSysTime(size_t row) const @safe
    {
        throw conversionError(row, "SysTime");
    }

    /// The value in `row` as a UUID.
    UUID getUUID(size_t row) const @safe
    {
        throw conversionError(row, "UUID");
    }

    /++
    The value in `row` as a `std.variant.Variant` holding the natural D type
    of the column (e.g. `ulong` for `UInt64`, `SysTime` for `DateTime`).
    A NULL value gives an empty `Variant`.
    +/
    abstract Variant getVariant(size_t row) const @safe;

    /// Creates the exception thrown when the value in `row` cannot be converted to `target`.
    protected ClientException conversionError(size_t row, string target) const @safe
    {
        import std.conv : to;

        return new ClientException(
                "Cannot convert the value in row " ~ row.to!string ~ " of column '" ~ name
                ~ "' (" ~ typeName ~ ") to " ~ target);
    }
}

/++
Base class of columns stored as an array of fixed-size values with the same
layout as the native format.
+/
abstract class FixedColumn(T) : Column if (isFixedWireType!T)
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
            readFixedValues(reader, data[start .. $]);
        }
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        writeFixedValues(writer, data);
    }
}

/// Reads `values.length` fixed-size little-endian values.
package void readFixedValues(T)(BufferedReader reader, T[] values) @safe
{
    version (LittleEndian)
        reader.readExact((() @trusted => cast(ubyte[]) values)()); // same memory layout as the wire
    else
    {
        foreach (ref v; values)
            v = reader.readFixed!T();
    }
}

/// Writes fixed-size values as little-endian.
package void writeFixedValues(T)(BufferedWriter writer, const(T)[] values) @safe
{
    version (LittleEndian)
        writer.writeBytes((() @trusted => cast(const(ubyte)[]) values)()); // same memory layout as the wire
    else
    {
        foreach (v; values)
            writer.writeFixed(v);
    }
}

/// Wraps a copy of `value` in a `Variant`, without type qualifiers, so that
/// `get!int` works for values read from a `const` column. Constructing a
/// Variant from a value is memory-safe, but `std.variant` is not annotated `@safe`.
package Variant makeVariant(T)(T value) @trusted
{
    import std.traits : Unqual;

    Unqual!T copy = value;
    return Variant(copy);
}
