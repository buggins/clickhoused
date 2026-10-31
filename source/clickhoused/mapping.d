/++
Mapping between D structs and table rows.

Fields map to columns of the same name; `@column("name")` maps a field to a
differently named column, and `@ignore` leaves a field out. Supported field
types: integers, floating-point numbers, `bool`, `string`, `ubyte[]`,
`std.datetime.Date`, `std.datetime.SysTime`, `std.uuid.UUID`, D enums
(matched to `Enum8`/`Enum16` labels or numeric values by member name/value),
and `std.typecons.Nullable` of these.

Example:
---
struct Trade
{
    @column("ts") SysTime time;
    string sym;
    double px;
    uint qty;
    @ignore string note;      // not stored
}

conn.insert("trades", trades);                                  // Trade[] or any range of Trade
foreach (t; conn.query!Trade("SELECT ts, sym, px, qty FROM trades"))
    writeln(t.sym, " ", t.px);
const total = conn.queryValue!ulong("SELECT count() FROM trades");
---

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.mapping;

import std.datetime.date : Date;
import std.datetime.systime : SysTime;
import std.meta : AliasSeq;
import std.traits : getUDAs, hasUDA, isDynamicArray, isFloatingPoint, isIntegral, isSigned, isSomeString, Unqual;
import std.typecons : Nullable;
import std.uuid : UUID;

import clickhoused.block : Block;
import clickhoused.connection : QueryResult, QueryStats;
import clickhoused.exception : ClientException;
import clickhoused.types.column : Column;

/// The value of a `@column("name")` attribute.
struct ColumnName
{
    /// Column name.
    string name;
}

/// The type of the `@ignore` attribute.
struct IgnoreField
{
}

/// UDA: maps a struct field to the column `name` instead of the field name.
ColumnName column(string name) @safe pure nothrow
{
    return ColumnName(name);
}

/// UDA: leaves a struct field out of the mapping.
enum ignore = IgnoreField();

/// The column names a struct maps to, in field order.
template columnNames(T) if (is(T == struct))
{
    enum string[] columnNames = () {
        string[] names;
        static foreach (i; 0 .. T.tupleof.length)
        {
            static if (!hasUDA!(T.tupleof[i], IgnoreField))
                names ~= fieldColumnName!(T, i);
        }
        return names;
    }();
}

///
@safe unittest
{
    struct Row
    {
        ulong id;
        @column("full_name") string name;
        @ignore int cache;
    }

    static assert(columnNames!Row == ["id", "full_name"]);
}

/++
Whether values of type `T` can be read from and written to columns: numbers,
`bool`, `string`, `ubyte[]`, `Date`, `SysTime`, `UUID`, D enums,
`std.typecons.Nullable` of these, and dynamic arrays of mappable values
(for `Array` columns; `ubyte[]` stays the type for `String` bytes).
+/
template isMappableValue(T)
{
    alias U = Unqual!T;
    static if (is(U : Nullable!V, V))
        enum isMappableValue = isMappableValue!V;
    else static if (isMappedArray!U)
        enum isMappableValue = isMappableValue!(typeof(U.init[0]));
    else
        enum isMappableValue = isIntegral!U || isFloatingPoint!U || is(U == bool) || is(U == string)
            || is(U == ubyte[]) || is(U == immutable(ubyte)[]) || is(U == Date) || is(U == SysTime) || is(U == UUID)
            || is(U == enum);
}

/// Whether `T` is a D array that maps to an `Array` column (strings and `ubyte[]` don't).
package enum bool isMappedArray(T) = isDynamicArray!T && !isSomeString!T && !is(Unqual!T : const(ubyte)[]);

/++
Reads the value in `row` of `column` as type `T`, converting with range checks.
An `Array` column reads into a D array, element by element.

Throws: `ClientException` if the value cannot be converted, or is NULL and
`T` is not a `Nullable`.
+/
T readValue(T)(Column column, size_t row) @safe if (isMappableValue!T)
{
    import std.conv : ConvException, to;

    alias U = Unqual!T;
    static if (is(U : Nullable!V, V))
    {
        if (column.isNull(row))
            return T.init;
        return T(readValue!V(column, row));
    }
    else
    {
        if (column.isNull(row))
            throw new ClientException("Column '" ~ column.name ~ "' has a NULL value, which " ~ U.stringof
                    ~ " cannot hold; use Nullable!" ~ U.stringof);
        static if (isMappedArray!U)
        {
            import clickhoused.types.array : ArrayColumn;

            auto array = cast(ArrayColumn) column;
            if (array is null)
                throw new ClientException("Column '" ~ column.name ~ "' (" ~ column.typeName
                        ~ ") is not an Array column, which " ~ U.stringof ~ " needs");
            U values;
            values.reserve(array.rowLength(row));
            foreach (i; array.rowStart(row) .. array.rowEnd(row))
                values ~= readValue!(typeof(U.init[0]))(array.elements, i);
            return values;
        }
        else static if (is(U == enum))
        {
            import clickhoused.types.misc : Enum16Column, Enum8Column;
            import clickhoused.types.string : StringColumn;

            if (cast(Enum8Column) column !is null || cast(Enum16Column) column !is null
                    || cast(StringColumn) column !is null)
            {
                const label = column.getString(row);
                try
                    return label.to!U;
                catch (ConvException)
                    throw new ClientException(
                            "Value '" ~ label ~ "' of column '" ~ column.name
                            ~ "' is not a member of " ~ U.stringof);
            }
            const value = column.getLong(row);
            foreach (member; __traits(allMembers, U))
                if (__traits(getMember, U, member) == value)
                    return __traits(getMember, U, member);
            throw new ClientException("Value of column '" ~ column.name ~ "' is not a member of " ~ U.stringof);
        }
        else static if (is(U == bool))
            return column.getBool(row);
        else static if (isIntegral!U)
        {
            static if (isSigned!U)
            {
                const v = column.getLong(row);
                if (v < U.min || v > U.max)
                    throw outOfRange!U(column);
            }
            else
            {
                const v = column.getUlong(row);
                if (v > U.max)
                    throw outOfRange!U(column);
            }
            return cast(U) v;
        }
        else static if (isFloatingPoint!U)
            return cast(U) column.getDouble(row);
        else static if (is(U == string))
            return column.getString(row);
        else static if (is(U == ubyte[]) || is(U == immutable(ubyte)[]))
            return column.getBytes(row).dup;
        else static if (is(U == Date))
            return column.getDate(row);
        else static if (is(U == SysTime))
            return column.getSysTime(row);
        else static if (is(U == UUID))
            return column.getUUID(row);
    }
}

/++
A query result as an input range of structs, created by `Connection.query!T`.

Rows are converted lazily, block by block. Like `QueryResult`, the range keeps
the connection busy until it is exhausted or closed.
+/
struct RowRange(T) if (is(T == struct))
{
    private QueryResult result_;
    private Block block;
    private Column[] bound; // the column of each mapped field
    private size_t row;
    private T current;
    private bool loaded;

    package this(QueryResult result) @safe
    {
        result_ = result;
    }

    /// Whether all rows have been consumed. Reads from the network if needed.
    @property bool empty() @safe
    {
        load();
        return !loaded;
    }

    /// The current row.
    @property T front() @safe
    {
        load();
        assert(loaded, "RowRange.front called on an empty range");
        return current;
    }

    /// Moves to the next row.
    void popFront() @safe
    {
        load();
        assert(loaded, "RowRange.popFront called on an empty range");
        loaded = false;
        row++;
    }

    /// The underlying block-level result: statistics, header, totals.
    @property QueryResult result() @safe pure nothrow
    {
        return result_;
    }

    /// Stops reading and frees the connection; see `QueryResult.close`.
    void close() @safe
    {
        result_.close();
        loaded = false;
        block = null;
    }

    private void load() @safe
    {
        if (loaded)
            return;
        while (block is null || row >= block.rows)
        {
            if (block !is null)
                result_.popFront();
            if (result_.empty)
            {
                block = null;
                return;
            }
            block = result_.front;
            try
                bound = bindColumns!T(block);
            catch (ClientException e)
            {
                result_.close(); // free the connection: the rest of the result is useless
                block = null;
                throw e;
            }
            row = 0;
        }
        current = readStruct!T(bound, row);
        loaded = true;
    }
}

/// Finds the column of each mapped field of `T` in `block`.
package Column[] bindColumns(T)(Block block) @safe
{
    Column[] bound;
    static foreach (name; columnNames!T)
    {
        {
            Column found;
            foreach (c; block.columns)
                if (c.name == name)
                {
                    found = c;
                    break;
                }
            if (found is null)
                throw new ClientException(
                        "The result has no column '" ~ name ~ "' for " ~ T.stringof
                        ~ "; columns: " ~ columnList(block));
            bound ~= found;
        }
    }
    return bound;
}

/// Builds a `T` from `row` of the columns returned by `bindColumns`.
package T readStruct(T)(Column[] bound, size_t row) @safe
{
    T value;
    size_t k;
    static foreach (i; 0 .. T.tupleof.length)
    {
        static if (!hasUDA!(T.tupleof[i], IgnoreField))
        {
            static assert(isMappableValue!(typeof(T.tupleof[i])), T.stringof ~ "." ~ __traits(identifier,
                    T.tupleof[i]) ~ ": fields of type " ~ typeof(T.tupleof[i]).stringof ~ " cannot be mapped");
            value.tupleof[i] = readValue!(typeof(T.tupleof[i]))(bound[k++], row);
        }
    }
    return value;
}

/// Indices of the mapped (non-ignored) fields of `T`.
package template mappedFields(T)
{
    template filter(size_t i)
    {
        static if (i == T.tupleof.length)
            alias filter = AliasSeq!();
        else static if (hasUDA!(T.tupleof[i], IgnoreField))
            alias filter = filter!(i + 1);
        else
            alias filter = AliasSeq!(i, filter!(i + 1));
    }

    alias mappedFields = filter!0;
}

private template fieldColumnName(T, size_t i)
{
    static if (hasUDA!(T.tupleof[i], ColumnName))
        enum fieldColumnName = getUDAs!(T.tupleof[i], ColumnName)[0].name;
    else
        enum fieldColumnName = __traits(identifier, T.tupleof[i]);
}

private ClientException outOfRange(U)(const Column column) @safe
{
    return new ClientException("Value of column '" ~ column.name ~ "' (" ~ column.typeName ~ ") does not fit "
            ~ U.stringof);
}

private string columnList(Block block) @safe
{
    string s;
    foreach (i, c; block.columns)
        s ~= (i ? ", " : "") ~ c.name;
    return s;
}

@safe unittest
{
    import std.datetime.timezone : UTC;
    import std.exception : assertThrown;
    import clickhoused.types.datetime : DateTimeColumn;
    import clickhoused.types.misc : Enum8Column, NullableColumn;
    import clickhoused.types.numeric : Int64Column, UInt8Column;
    import clickhoused.types.string : StringColumn;

    enum Side
    {
        buy = 1,
        sell = 2
    }

    struct Trade
    {
        @column("ts") SysTime time;
        string sym;
        int qty;
        Side side;
        Nullable!long note;
        @ignore string cache;
    }

    auto ts = new DateTimeColumn("ts", "DateTime('UTC')", "UTC");
    ts.data = [0, 60];
    auto sym = new StringColumn("sym");
    sym.data = ["A", "B"];
    auto qty = new Int64Column("qty", "Int64");
    qty.data = [5, 7];
    auto side = new Enum8Column("side", "Enum8('buy' = 1, 'sell' = 2)", ["buy": 1, "sell": 2]);
    side.data = [2, 1];
    auto noteValues = new Int64Column("note", "Int64");
    noteValues.data = [0, 3];
    auto note = new NullableColumn("note", "Nullable(Int64)", noteValues);
    note.nulls = [true, false];
    auto extra = new UInt8Column("extra", "UInt8");
    extra.data = [0, 0];

    auto block = new Block;
    block.columns = [extra, note, side, qty, sym, ts]; // any order, extra columns ignored
    block.rows = 2;
    auto bound = bindColumns!Trade(block);
    const first = readStruct!Trade(bound, 0);
    const second = readStruct!Trade(bound, 1);
    assert(first.time == SysTime.fromUnixTime(0, UTC()) && first.sym == "A" && first.qty == 5);
    assert(first.side == Side.sell && first.note.isNull);
    assert(second.side == Side.buy && second.note.get == 3);

    // Range checks and NULL handling
    qty.data[0] = long.max;
    assertThrown!ClientException(readStruct!Trade(bound, 0));
    assertThrown!ClientException(readValue!long(note, 0)); // NULL into a non-Nullable
    block.columns = [ts, sym];
    assertThrown!ClientException(bindColumns!Trade(block)); // missing columns
}

// D arrays to and from Array columns
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.insert : appendValue;
    import clickhoused.types.array : ArrayColumn;
    import clickhoused.types.factory : createColumn;

    auto ints = cast(ArrayColumn) createColumn("a", "Array(Nullable(Int32))");
    appendValue(ints, [Nullable!int(1), Nullable!int.init]);
    appendValue(ints, cast(long[]) null);
    assert(readValue!(Nullable!int[])(ints, 0) == [Nullable!int(1), Nullable!int.init]);
    assert(readValue!(long[])(ints, 1) == []);
    assertThrown!ClientException(readValue!(int[])(ints, 0)); // NULL element
    assertThrown!ClientException(appendValue(ints, [1L, 99_999_999_999L])); // out of range
    assert(ints.length == 2 && ints.elements.length == 2); // the failed row left no trace

    auto nested = createColumn("n", "Array(Array(String))");
    appendValue(nested, [["a", "b"], []]);
    assert(readValue!(string[][])(nested, 0) == [["a", "b"], []]);
    assert(readValue!string(nested, 0) == "[['a','b'],[]]");

    // ubyte[] stays the type for String bytes, and also fills Array(UInt8)
    auto bytes = createColumn("b", "Array(UInt8)");
    appendValue(bytes, cast(const(ubyte)[])[1, 2]);
    assert(readValue!(ubyte[])(bytes, 0) == [1, 2] && readValue!(int[])(bytes, 0) == [1, 2]);

    auto plain = createColumn("s", "String");
    assertThrown!ClientException(appendValue(plain, [1, 2]));
    appendValue(plain, "x");
    assertThrown!ClientException(readValue!(int[])(plain, 0));
}
