/++
Blocks: the unit of data exchange in the native protocol, a set of named
columns with the same number of rows.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.block;

import clickhoused.exception : ClientException, ProtocolException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.protocol.codes : Revision;
import clickhoused.types.column : Column;
import clickhoused.types.factory : createColumn;

/// Extra block attributes, used by distributed aggregation.
struct BlockInfo
{
    /// Whether the block contains rows that exceed `max_rows_to_group_by`.
    bool isOverflows;
    /// Two-level aggregation bucket number, or -1.
    int bucketNum = -1;
}

/// A set of named columns with the same number of rows.
final class Block
{
    /// Extra attributes.
    BlockInfo info;
    /// Columns, in result order.
    Column[] columns;
    /// Number of rows.
    size_t rows;

    /++
    Returns the index of the column named `name`.

    Throws: `ClientException` if there is no such column.
    +/
    size_t columnIndex(string name) const @safe
    {
        foreach (i, c; columns)
            if (c.name == name)
                return i;
        throw new ClientException("No column named '" ~ name ~ "'");
    }

    /++
    Returns the column named `name`, cast to the column class `C`. For a
    `LowCardinality(T)` column, `C` may also be the class of `T`: the decoded
    values are returned (see `LowCardinalityColumn`).

    Throws: `ClientException` if there is no such column, or it is not a `C`.
    +/
    C column(C : Column = Column)(string name) @safe
    {
        import clickhoused.types.lowcardinality : LowCardinalityColumn;

        const index = columnIndex(name);
        auto c = cast(C) columns[index];
        // A LowCardinality(T) column is used like a T column
        if (c is null)
            if (auto lc = cast(LowCardinalityColumn) columns[index])
                c = cast(C) lc.values;
        if (c is null)
            throw new ClientException(
                    "Column '" ~ name ~ "' of type " ~ columns[columnIndex(name)].typeName
                    ~ " is not a " ~ C.stringof);
        return c;
    }
}

///
@safe unittest
{
    import clickhoused.types.numeric : UInt64Column;

    auto block = new Block;
    auto ids = new UInt64Column("id", "UInt64");
    ids.data = [1, 2, 3];
    block.columns = [ids];
    block.rows = 3;

    assert(block.column!UInt64Column("id").data == [1, 2, 3]);
}

/// Upper bound for the number of columns in a received block.
private enum size_t maxBlockColumns = 1_000_000;

/++
Reads a block in the native format at protocol revision `revision`.

`defaultTimezone` is the timezone for `DateTime` columns whose type has no
explicit timezone; normally the server timezone.

Throws:
    `ProtocolException` on malformed data;
    `ClientException` if a column has a type this version does not support.
    In both cases the stream position is lost and the connection must be closed.
+/
Block readBlock(BufferedReader reader, ulong revision, string defaultTimezone = null) @safe
{
    auto block = new Block;
    if (revision > 0)
        block.info = readBlockInfo(reader);

    const columnCount = reader.readUVarInt();
    const rowCount = reader.readUVarInt();
    if (columnCount > maxBlockColumns)
        throw new ProtocolException("Too many columns in a block");
    if (rowCount > size_t.max)
        throw new ProtocolException("Too many rows in a block");
    block.rows = cast(size_t) rowCount;

    foreach (i; 0 .. cast(size_t) columnCount)
    {
        const name = reader.readString();
        const typeName = reader.readString();
        if (revision >= Revision.withCustomSerialization && reader.readByte() != 0)
            throw new ProtocolException("Column '" ~ name ~ "': custom serialization is not supported");
        auto column = createColumn(name, typeName, defaultTimezone);
        if (block.rows) // a block without rows has no column data at all
        {
            column.readStatePrefix(reader);
            column.readData(reader, block.rows);
        }
        block.columns ~= column;
    }
    return block;
}

/// Writes `block` in the native format at protocol revision `revision`.
void writeBlock(BufferedWriter writer, Block block, ulong revision) @safe
{
    if (revision > 0)
        writeBlockInfo(writer, block.info);
    writer.writeUVarInt(block.columns.length);
    writer.writeUVarInt(block.rows);
    foreach (column; block.columns)
    {
        if (column.length != block.rows)
            throw new ClientException("Column '" ~ column.name ~ "' has a different number of rows than the block");
        writer.writeString(column.name);
        writer.writeString(column.typeName);
        if (revision >= Revision.withCustomSerialization)
            writer.writeByte(0); // default serialization
        if (block.rows)
        {
            column.writeStatePrefix(writer);
            column.writeData(writer);
        }
    }
}

/// Writes an empty block: the end-of-data marker of the native protocol.
void writeEmptyBlock(BufferedWriter writer, ulong revision) @safe
{
    writeBlock(writer, new Block, revision);
}

private BlockInfo readBlockInfo(BufferedReader reader) @safe
{
    import std.conv : to;

    BlockInfo info;
    for (;;)
    {
        const field = reader.readUVarInt();
        switch (field)
        {
        case 0:
            return info;
        case 1:
            info.isOverflows = reader.readFixed!bool();
            break;
        case 2:
            info.bucketNum = reader.readFixed!int();
            break;
        default:
            throw new ProtocolException("Unknown block info field " ~ field.to!string);
        }
    }
}

private void writeBlockInfo(BufferedWriter writer, BlockInfo info) @safe
{
    writer.writeUVarInt(1);
    writer.writeFixed(info.isOverflows);
    writer.writeUVarInt(2);
    writer.writeFixed(info.bucketNum);
    writer.writeUVarInt(0);
}

@safe unittest
{
    import clickhoused.io.mock : MockTransport;
    import clickhoused.types.numeric : UInt8Column;
    import clickhoused.types.string : StringColumn;

    // Block round trip
    auto t = new MockTransport;
    auto w = new BufferedWriter(t);
    auto block = new Block;
    auto n = new UInt8Column("n", "UInt8");
    n.data = [1, 2];
    auto s = new StringColumn("s");
    s.data = ["a", "bc"];
    block.columns = [n, s];
    block.rows = 2;
    writeBlock(w, block, Revision.client);
    writeEmptyBlock(w, Revision.client);
    w.flush();

    t.feed(t.written);
    auto r = new BufferedReader(t);
    auto b = readBlock(r, Revision.client);
    assert(b.rows == 2 && b.columns.length == 2);
    assert(b.column!UInt8Column("n").data == [1, 2]);
    assert(b.column!StringColumn("s").data == ["a", "bc"]);
    assert(b.info.bucketNum == -1);
    const empty = readBlock(r, Revision.client);
    assert(empty.rows == 0 && empty.columns.length == 0);
    assert(t.remaining == 0);
}

@safe unittest
{
    // Empty block bytes: block info (field 1 = false, field 2 = -1, end), 0 columns, 0 rows
    import clickhoused.io.mock : MockTransport;

    auto t = new MockTransport;
    auto w = new BufferedWriter(t);
    writeEmptyBlock(w, Revision.client);
    w.flush();
    assert(t.written == [1, 0, 2, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0]);
}
