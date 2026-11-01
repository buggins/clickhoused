/++
String columns: `String` and `FixedString(N)`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.string;

import std.conv : ConvException, to;
import std.variant : Variant;

import clickhoused.exception : ClientException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter, StringArena;
import clickhoused.types.column;

/++
`String` column. Values are arbitrary bytes, not necessarily valid UTF-8.

`getLong`, `getUlong` and `getDouble` parse the text and throw
`ClientException` if it is not a number.

Decoded values are slices of a few shared buffers (up to 64 KB each), not one
allocation per value: keeping one value alive keeps its buffer alive. `.idup`
a value to keep it apart.
+/
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

    /// Reads `rows` values; their bytes share a few large buffers (see `StringArena`).
    override void readData(BufferedReader reader, size_t rows) @safe
    {
        data = null;
        StringArena arena;
        while (data.length < rows)
        {
            // At once for moderate counts; a huge count claimed by a broken stream grows as data arrives
            const start = data.length;
            data.length = growRows(start, rows);
            foreach (ref value; data[start .. $])
                value = reader.readString(arena);
        }
    }

    override void writeData(BufferedWriter writer) const @safe
    {
        foreach (v; data)
            writer.writeString(v);
    }

    /// Quoted inside arrays.
    override protected @property bool quotedInText() const @safe pure nothrow
    {
        return true;
    }

    override string getString(size_t row) const @safe
    {
        return data[row];
    }

    override const(ubyte)[] getBytes(size_t row) const @safe
    {
        return cast(const(ubyte)[]) data[row];
    }

    override long getLong(size_t row) const @safe
    {
        return parse!long(row);
    }

    override ulong getUlong(size_t row) const @safe
    {
        return parse!ulong(row);
    }

    override double getDouble(size_t row) const @safe
    {
        return parse!double(row);
    }

    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(data[row]);
    }

    override void appendDefault() @safe
    {
        data ~= "";
    }

    override void truncate(size_t length) @safe
    {
        if (length < data.length)
            data.length = length;
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        data ~= sameKind!StringColumn(source).data[row];
    }

    override void appendString(string value) @safe
    {
        data ~= value;
    }

    override void appendBytes(const(ubyte)[] value) @safe
    {
        data ~= cast(string) value.idup;
    }

    private T parse(T)(size_t row) const @safe
    {
        try
            return data[row].to!T;
        catch (ConvException)
            throw conversionError(row, T.stringof);
    }
}

///
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.exception : ClientException;

    auto c = new StringColumn("s");
    c.data = ["42", "abc"];
    assert(c.getLong(0) == 42);
    assert(c.getString(1) == "abc");
    assertThrown!ClientException(c.getLong(1));
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

    override void writeData(BufferedWriter writer) const @safe
    {
        writer.writeBytes(bytes);
    }

    /// Returns the value with trailing zero bytes removed, as `asString` does.
    /// Quoted with its zero padding, as ClickHouse writes it inside arrays (`'ab\0'`).
    override string getQuotedString(size_t row) const @safe
    {
        import clickhoused.types.column : quoteText;

        return quoteText(cast(const(char)[]) this[row]);
    }

    override string getString(size_t row) const @safe
    {
        return asString(row);
    }

    override const(ubyte)[] getBytes(size_t row) const @safe
    {
        return this[row];
    }

    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(asString(row));
    }

    override void appendDefault() @safe
    {
        bytes.length += width;
    }

    override void truncate(size_t length) @safe
    {
        if (length < this.length)
            bytes.length = length * width;
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        auto other = sameKind!FixedStringColumn(source);
        if (other.width != width)
            throw new ClientException("Column '" ~ name ~ "': cannot copy values of a different FixedString width");
        bytes ~= other[row];
    }

    /// Appends `value` padded with zero bytes. Values longer than `width` are rejected.
    override void appendString(string value) @safe
    {
        appendBytes(cast(const(ubyte)[]) value);
    }

    /// ditto
    override void appendBytes(const(ubyte)[] value) @safe
    {
        if (value.length > width)
            throw appendError("bytes", value.length);
        bytes ~= value;
        bytes.length += width - value.length;
    }
}

///
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.exception : ClientException;

    auto c = new FixedStringColumn("code", 3, "FixedString(3)");
    c.appendString("ab");
    c.appendDefault();
    assert(c.bytes == ['a', 'b', 0, 0, 0, 0]);
    assertThrown!ClientException(c.appendString("abcd"));
}
