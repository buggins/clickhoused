/++
`LowCardinality(T)` columns.

On the wire a LowCardinality column is dictionary-encoded: per block, a list
of distinct keys and one index per row. clickhoused decodes it into a plain
column of type `T` (`LowCardinalityColumn.values`), so the values are used
exactly like those of a `T` column, and encodes it again when sending.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.lowcardinality;

import core.time : Duration;
import std.datetime.date : Date;
import std.datetime.systime : SysTime;
import std.uuid : UUID;
import std.variant : Variant;

import clickhoused.exception : ClientException, ProtocolException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.types.column : Column, readChunkRows;
import clickhoused.types.misc : NullableColumn;
import clickhoused.types.string : StringColumn;

// Wire constants, from ClickHouse's SerializationLowCardinality.cpp
private enum ulong keysVersion = 1; // SharedDictionariesWithAdditionalKeys
private enum ulong needGlobalDictionaryBit = 1UL << 8;
private enum ulong hasAdditionalKeysBit = 1UL << 9;
private enum ulong needUpdateDictionaryBit = 1UL << 10;
private enum ulong indexTypeMask = 0xFF;

/++
`LowCardinality(T)` column, decoded: `values` holds the values as a plain
column of type `T`, e.g. a `StringColumn` for `LowCardinality(String)` or a
`NullableColumn` for `LowCardinality(Nullable(String))`.

All getters and appenders work on `values`. `Block.column!StringColumn("lc")`
returns `values` for such a column, so code written for the plain type keeps
working.
+/
final class LowCardinalityColumn : Column
{
    /// The values, as a column of the inner type `T`.
    Column values;

    private Column delegate() @safe newKeys; // empty column of the non-Nullable inner type

    /++
    Creates an empty column.

    Params:
        name = column name.
        typeName = ClickHouse type name.
        values = empty column of the inner type.
        newKeys = creates an empty column of the inner type without `Nullable`, for dictionaries.
    +/
    this(string name, string typeName, Column values, Column delegate() @safe newKeys) @safe pure nothrow
    {
        super(name, typeName);
        this.values = values;
        this.newKeys = newKeys;
    }

    override @property size_t length() const @safe pure nothrow
    {
        return values.length;
    }

    /// Reads and checks the key serialization version.
    override void readStatePrefix(BufferedReader reader) @safe
    {
        if (reader.readFixed!ulong() != keysVersion)
            throw new ProtocolException("Column '" ~ name ~ "': unknown LowCardinality serialization version");
    }

    /// Writes the key serialization version.
    override void writeStatePrefix(BufferedWriter writer) const @safe
    {
        writer.writeFixed!ulong(keysVersion);
    }

    override void readData(BufferedReader reader, size_t rows) @safe
    {
        values.truncate(0);
        auto nullable = cast(NullableColumn) values;
        // The data may come in several parts, each with its own keys
        while (values.length < rows)
        {
            const indexType = reader.readFixed!ulong();
            if ((indexType & needGlobalDictionaryBit) || !(indexType & hasAdditionalKeysBit)
                    || (indexType & ~(
                        indexTypeMask | needGlobalDictionaryBit | hasAdditionalKeysBit
                        | needUpdateDictionaryBit)) || (indexType & indexTypeMask) > 3)
                throw new ProtocolException("Column '" ~ name ~ "': unsupported LowCardinality index type");
            const width = size_t(1) << (indexType & indexTypeMask); // 1, 2, 4 or 8 bytes

            const keyCount = reader.readFixed!ulong();
            if (keyCount > size_t.max)
                throw new ProtocolException("Column '" ~ name ~ "': too many LowCardinality keys");
            auto keys = newKeys();
            keys.readData(reader, cast(size_t) keyCount); // grows with the data actually received

            const count = reader.readFixed!ulong();
            if (count == 0 || count > rows - values.length)
                throw new ProtocolException("Column '" ~ name ~ "': wrong LowCardinality row count");
            ulong[] chunk;
            for (size_t done = 0; done < count;)
            {
                const n = count - done < readChunkRows ? cast(size_t)(count - done) : readChunkRows;
                chunk.length = n;
                readIndexes(reader, chunk, width);
                foreach (index; chunk)
                {
                    if (index >= keyCount)
                        throw new ProtocolException("Column '" ~ name ~ "': LowCardinality index out of range");
                    if (nullable is null)
                        values.appendFrom(keys, cast(size_t) index);
                    else if (index == 0) // stands for NULL
                        nullable.appendNull();
                    else
                    {
                        nullable.nested.appendFrom(keys, cast(size_t) index);
                        nullable.appendFlag(false);
                    }
                }
                done += n;
            }
        }
    }

    /// Writes the values with a dictionary of their distinct values, as ClickHouse does.
    override void writeData(BufferedWriter writer) const @safe
    {
        const rows = values.length;
        if (rows == 0)
            return; // ClickHouse writes nothing for an empty column (e.g. inside empty arrays)

        auto nullable = cast(const NullableColumn) values;
        const plain = nullable is null ? values : nullable.nested;
        auto strings = cast(const StringColumn) plain;
        auto keys = newKeys();
        if (nullable !is null)
            keys.appendDefault(); // index 0 stands for NULL
        size_t[string] positions;
        auto indexes = new ulong[rows];
        foreach (row; 0 .. rows)
        {
            if (nullable !is null && nullable.nulls[row])
                continue; // index 0
            // Strings are the common case; other types are told apart by their exact text
            const key = strings !is null ? strings.data[row] : plain.getQuotedString(row);
            if (auto found = key in positions)
                indexes[row] = *found;
            else
            {
                positions[key] = keys.length;
                indexes[row] = keys.length;
                keys.appendFrom(plain, row);
            }
        }

        const indexType = keys.length <= 0x100 ? 0 : keys.length <= 0x1_0000 ? 1 : keys.length <= 0x1_0000_0000 ? 2 : 3;
        writer.writeFixed!ulong(indexType | hasAdditionalKeysBit | needUpdateDictionaryBit);
        writer.writeFixed!ulong(keys.length);
        keys.writeData(writer);
        writer.writeFixed!ulong(rows);
        foreach (index; indexes) final switch (indexType)
        {
        case 0:
            writer.writeFixed!ubyte(cast(ubyte) index);
            break;
        case 1:
            writer.writeFixed!ushort(cast(ushort) index);
            break;
        case 2:
            writer.writeFixed!uint(cast(uint) index);
            break;
        case 3:
            writer.writeFixed!ulong(index);
            break;
        }
    }

    override @property bool isNullable() const @safe pure nothrow
    {
        return values.isNullable;
    }

    override bool isNull(size_t row) const @safe
    {
        return values.isNull(row);
    }

    override long getLong(size_t row) const @safe
    {
        return values.getLong(row);
    }

    override ulong getUlong(size_t row) const @safe
    {
        return values.getUlong(row);
    }

    override double getDouble(size_t row) const @safe
    {
        return values.getDouble(row);
    }

    override bool getBool(size_t row) const @safe
    {
        return values.getBool(row);
    }

    override string getString(size_t row) const @safe
    {
        return values.getString(row);
    }

    override string getQuotedString(size_t row) const @safe
    {
        return values.getQuotedString(row);
    }

    override const(ubyte)[] getBytes(size_t row) const @safe
    {
        return values.getBytes(row);
    }

    override Date getDate(size_t row) const @safe
    {
        return values.getDate(row);
    }

    override SysTime getSysTime(size_t row) const @safe
    {
        return values.getSysTime(row);
    }

    override UUID getUUID(size_t row) const @safe
    {
        return values.getUUID(row);
    }

    override Duration getDuration(size_t row) const @safe
    {
        return values.getDuration(row);
    }

    override Variant getVariant(size_t row) const @safe
    {
        return values.getVariant(row);
    }

    override void truncate(size_t length) @safe
    {
        values.truncate(length);
    }

    override void appendDefault() @safe
    {
        values.appendDefault();
    }

    override void appendNull() @safe
    {
        values.appendNull();
    }

    override void appendLong(long value) @safe
    {
        values.appendLong(value);
    }

    override void appendUlong(ulong value) @safe
    {
        values.appendUlong(value);
    }

    override void appendDouble(double value) @safe
    {
        values.appendDouble(value);
    }

    override void appendBool(bool value) @safe
    {
        values.appendBool(value);
    }

    override void appendString(string value) @safe
    {
        values.appendString(value);
    }

    override void appendBytes(const(ubyte)[] value) @safe
    {
        values.appendBytes(value);
    }

    override void appendDate(Date value) @safe
    {
        values.appendDate(value);
    }

    override void appendSysTime(SysTime value) @safe
    {
        values.appendSysTime(value);
    }

    override void appendUUID(UUID value) @safe
    {
        values.appendUUID(value);
    }

    override void appendDuration(Duration value) @safe
    {
        values.appendDuration(value);
    }

    /// Copies a value from another LowCardinality column, or from a column of the inner type.
    override void appendFrom(const Column source, size_t row) @safe
    {
        auto other = cast(const LowCardinalityColumn) source;
        values.appendFrom(other is null ? source : other.values, row);
    }
}

/// Reads `indexes.length` little-endian unsigned indexes of `width` bytes.
private void readIndexes(BufferedReader reader, ulong[] indexes, size_t width) @safe
{
    final switch (width)
    {
    case 1:
        foreach (ref i; indexes)
            i = reader.readFixed!ubyte();
        break;
    case 2:
        foreach (ref i; indexes)
            i = reader.readFixed!ushort();
        break;
    case 4:
        foreach (ref i; indexes)
            i = reader.readFixed!uint();
        break;
    case 8:
        foreach (ref i; indexes)
            i = reader.readFixed!ulong();
        break;
    }
}

///
@safe unittest
{
    import clickhoused.types.factory : createColumn;

    auto c = cast(LowCardinalityColumn) createColumn("city", "LowCardinality(String)");
    c.appendString("Lisbon");
    c.appendString("Porto");
    assert(c.getString(1) == "Porto");
    assert((cast(StringColumn) c.values).data == ["Lisbon", "Porto"]); // decoded, as a plain column
}

version (unittest)
{
    private Column readGolden(string type, size_t rows, const(ubyte)[] bytes) @safe
    {
        import clickhoused.io.mock : MockTransport;
        import clickhoused.types.factory : createColumn;

        auto t = new MockTransport;
        t.feed(bytes);
        auto r = new BufferedReader(t);
        auto c = createColumn("lc", type);
        c.readStatePrefix(r);
        c.readData(r, rows);
        assert(t.remaining == 0, type);
        return c;
    }

    private const(ubyte)[] written(const Column c) @safe
    {
        import clickhoused.io.mock : MockTransport;

        auto t = new MockTransport;
        auto w = new BufferedWriter(t);
        c.writeStatePrefix(w);
        c.writeData(w);
        w.flush();
        return t.written;
    }

    private string[] texts(const Column c) @safe
    {
        string[] result;
        foreach (row; 0 .. c.length)
            result ~= c.isNull(row) ? "NULL" : c.getString(row);
        return result;
    }

    private immutable ubyte[] le8 = [1, 0, 0, 0, 0, 0, 0, 0]; // the key version prefix

    private const(ubyte)[] withPrefix(const(ubyte)[] data) @safe
    {
        return le8 ~ data;
    }
}

// Golden bytes from `clickhouse client --low_cardinality_allow_in_native_format=1 -q "... FORMAT Native"`
@safe unittest
{
    // SELECT toLowCardinality(toString(number % 3)) FROM numbers(5)
    const strings = readGolden("LowCardinality(String)", 5, withPrefix([
        0, 6, 0, 0, 0, 0, 0, 0, // index type: UInt8 | has additional keys | update dictionary
        4, 0, 0, 0, 0, 0, 0, 0, 0, 1, '0', 1, '1', 1, '2', // keys "", "0", "1", "2"
        5, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 1,
        2 // rows and indexes
    ]));
    assert(texts(strings) == ["0", "1", "2", "0", "1"]);

    // SELECT CAST(arrayJoin(['b', NULL, 'a', 'b']) AS LowCardinality(Nullable(String)))
    const nullable = readGolden("LowCardinality(Nullable(String))", 4, withPrefix([
        0, 6, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 'b', 1, 'a', // keys: NULL, "", "b", "a"
        4, 0, 0, 0, 0, 0, 0, 0, 2, 0, 3, 2
    ]));
    assert(texts(nullable) == ["b", "NULL", "a", "b"] && nullable.isNullable);

    // SELECT CAST(['x','y','x'] AS Array(LowCardinality(String))): the prefix comes before the offsets
    const array = readGolden("Array(LowCardinality(String))", 1, withPrefix([
        3, 0, 0, 0, 0, 0, 0, 0, // offsets
        0, 6, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 1, 'x', 1, 'y', 3, 0, 0, 0, 0, 0, 0, 0, 1,
        2, 1
    ]));
    assert(array.getString(0) == "['x','y','x']");

    // What we write reads back to the same values
    foreach (c; [strings, nullable, array])
        assert(texts(readGolden(c.typeName, c.length, written(c))) == texts(c), c.typeName);
}

// The encoding we write: distinct keys in order of appearance, NULL as index 0
@safe unittest
{
    import clickhoused.types.factory : createColumn;

    auto c = createColumn("lc", "LowCardinality(Nullable(String))");
    foreach (v; ["a", null, "b", "a"])
        if (v is null)
            c.appendNull();
        else
            c.appendString(v);
    assert(written(c) == withPrefix([
        0, 6, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 1, 'a', 1, 'b', 4, 0, 0, 0, 0, 0, 0, 0, 1,
        0, 2, 1
    ]));

    // 300 distinct values need UInt16 indexes; non-string types are keyed by their text
    auto dates = createColumn("d", "LowCardinality(Date)");
    foreach (i; 0 .. 600)
        dates.appendLong(i % 300);
    const bytes = written(dates);
    assert(bytes[8] == 1 && bytes[9] == 6); // UInt16 indexes
    assert(texts(readGolden("LowCardinality(Date)", 600, bytes)) == texts(dates));

    // An empty column (e.g. the elements of empty arrays) writes no data
    assert(written(createColumn("e", "LowCardinality(String)")) == le8);
}

// Data in several parts, each with its own keys; malformed input
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.exception : ConnectionException;

    const part1 = cast(const(ubyte)[])[
        0, 6, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 'p', 1, 0, 0, 0, 0, 0, 0,
        0, 0
    ];
    const part2 = cast(const(ubyte)[])[
        0, 6, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 'q', 2, 0, 0, 0, 0, 0, 0,
        0, 0, 0
    ];
    assert(texts(readGolden("LowCardinality(String)", 3, le8 ~ part1 ~ part2)) == ["p", "q", "q"]);

    alias bad = (const(ubyte)[] bytes) => readGolden("LowCardinality(String)", 1, bytes);
    assertThrown!ProtocolException(bad([2, 0, 0, 0, 0, 0, 0, 0])); // unknown version
    assertThrown!ProtocolException(bad(withPrefix([0, 7, 0, 0, 0, 0, 0, 0]))); // global dictionary
    assertThrown!ProtocolException(bad(withPrefix([0, 4, 0, 0, 0, 0, 0, 0]))); // no keys
    assertThrown!ProtocolException(bad(withPrefix([4, 6, 0, 0, 0, 0, 0, 0]))); // index width
    // index 5 with 1 key; then 2 rows for a 1-row column
    assertThrown!ProtocolException(bad(withPrefix([
        0, 6, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0,
        0, 0, 5
    ])));
    assertThrown!ProtocolException(bad(withPrefix([
        0, 6, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0,
        0, 0, 0, 0
    ])));
    // a huge key count with no data behind it fails without allocating the keys
    bool failed;
    try
        bad(withPrefix([0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0]));
    catch (ConnectionException)
        failed = true;
    catch (ProtocolException)
        failed = true;
    assert(failed);
}

// Block.column!T finds the decoded values of a LowCardinality(T) column
@safe unittest
{
    import clickhoused.block : Block;
    import clickhoused.types.factory : createColumn;

    auto block = new Block;
    auto c = createColumn("lc", "LowCardinality(String)");
    c.appendString("x");
    block.columns = [c];
    block.rows = 1;
    assert(block.column!StringColumn("lc").data == ["x"]);
    assert(block.column!LowCardinalityColumn("lc") is c);
}
