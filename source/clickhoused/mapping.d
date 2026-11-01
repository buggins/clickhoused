/++
Mapping between D structs and table rows.

Fields map to columns of the same name; `@column("name")` maps a field to a
differently named column, and `@ignore` leaves a field out. Supported field
types: integers, floating-point numbers, `bool`, `string`, `ubyte[]`,
`std.datetime.Date`, `std.datetime.SysTime`, `core.time.Duration` and
`std.datetime.TimeOfDay` (for `Time` and `Time64`), `std.uuid.UUID`, D enums
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

import core.time : Duration;
import std.bigint : BigInt;
import std.datetime.date : Date, TimeOfDay;
import std.datetime.systime : SysTime;
import std.meta : AliasSeq;
import std.traits : getUDAs, hasUDA, isAssociativeArray, isDynamicArray, isFloatingPoint, isIntegral, isSigned,
    isSomeString, KeyType, Unqual, ValueType;
import std.typecons : Nullable;
import std.json : JSONValue;
import std.uuid : UUID;
import std.variant : Variant;

import clickhoused.block : Block;
import clickhoused.connection : QueryResult, QueryStats;
import clickhoused.exception : ClientException;
import clickhoused.types.column : Column;
import clickhoused.types.decimal : Decimal, decimalAt;
import clickhoused.types.ip : IPv4, IPv4Column, IPv6, IPv6Column;
import clickhoused.types.wideint : isWideInt, WideIntColumn;

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
`Int128`, `UInt128`, `Int256`, `UInt256`, `std.bigint.BigInt` (any integer
column), `Decimal` (any numeric column), `IPv4`, `IPv6`, structs and
`std.typecons.Tuple` (for `Tuple` columns, see `isTupleValue`), associative
arrays `V[K]` (for `Map` columns), `std.variant.Variant` (any column: the value of `getVariant`,
NULL as an empty `Variant`), `bool`, `string`, `ubyte[]`, `Date`, `SysTime`, `Duration`,
`TimeOfDay` (from 00:00:00 to 23:59:59), `std.json.JSONValue` (`JSON` columns, or JSON text in any
column), `UUID`, D enums,
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
    else static if (isAssociativeArray!U)
        enum isMappableValue = isMappableValue!(KeyType!U) && isMappableValue!(ValueType!U);
    else static if (isTupleValue!U)
        enum isMappableValue = true;
    else
        enum isMappableValue = isIntegral!U || isFloatingPoint!U || is(U == bool) || is(U == string)
            || is(U == ubyte[]) || is(U == immutable(ubyte)[]) || is(U == Date) || is(U == SysTime) || is(U == UUID)
            || is(U == Duration) || is(U == TimeOfDay) || is(U == Variant) || is(U == JSONValue)
            || is(U == enum) || isWideInt!U || is(U == BigInt) || is(U == Decimal) || is(U == IPv4)
            || is(U == IPv6);
}

/++
Whether `T` is a struct that maps to a `Tuple` column: any struct (including
`std.typecons.Tuple`) whose mapped fields are all mappable values, other than
the structs that are values themselves (`Date`, `SysTime`, `Decimal`, ...).
+/
package template isTupleValue(T)
{
    static if (is(T == struct) && !is(T == Date) && !is(T == SysTime) && !is(T == UUID) && !is(T == Duration)
            && !is(T == TimeOfDay) && !is(T == Variant) && !is(T == JSONValue) && !isWideInt!T
            && !is(T == BigInt) && !is(T == Decimal) && !is(T == IPv4) && !is(T == IPv6) && !is(T : Nullable!V, V))
        enum isTupleValue = () {
            bool all = true;
            static foreach (i; 0 .. T.tupleof.length)
                {
                static if (!hasUDA!(T.tupleof[i], IgnoreField))
                    all = all && isMappableValue!(typeof(T.tupleof[i]));
            }
            return all;
        }();
    else
        enum isTupleValue = false;
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
    else static if (is(U == Variant))
    {
        // Any column, NULL as an empty Variant; std.variant is not annotated @safe, but copying is memory-safe
        return (() @trusted => column.getVariant(row))();
    }
    else
    {
        if (column.isNull(row))
            throw new ClientException("Column '" ~ column.name ~ "' has a NULL value, which " ~ U.stringof
                    ~ " cannot hold; use Nullable!" ~ U.stringof);
        {
            // A Variant cell reads as the value in its alternative's column
            import clickhoused.types.variant : VariantColumn;

            if (auto variant = cast(VariantColumn) column)
                return readValue!T(variant.variants[variant.discriminators[row]], variant.position(row));

            import clickhoused.types.dynamic : DynamicColumn;

            if (auto dynamic = cast(DynamicColumn) column)
            {
                size_t position;
                dynamic.held(row, position); // throws for NULL and undecodable values
                return readValue!T(dynamic.values.variants[dynamic.values.discriminators[row]], position);
            }
        }
        static if (isMappedArray!U)
        {
            import clickhoused.types.array : ArrayColumn;

            import clickhoused.types.map : MapColumn;

            auto array = cast(ArrayColumn) column;
            if (array is null)
                if (auto map = cast(MapColumn) column)
                    array = map.entries; // a Map is an array of (key, value) tuples
            if (array is null)
                throw new ClientException("Column '" ~ column.name ~ "' (" ~ column.typeName
                        ~ ") is not an Array column, which " ~ U.stringof ~ " needs");
            U values;
            values.reserve(array.rowLength(row));
            foreach (i; array.rowStart(row) .. array.rowEnd(row))
                values ~= readValue!(typeof(U.init[0]))(array.elements, i);
            return values;
        }
        else static if (isAssociativeArray!U)
        {
            import clickhoused.types.map : MapColumn;

            auto map = cast(MapColumn) column;
            if (map is null)
                throw new ClientException("Column '" ~ column.name ~ "' (" ~ column.typeName
                        ~ ") is not a Map column, which " ~ U.stringof ~ " needs");
            U values;
            foreach (i; map.rowStart(row) .. map.rowEnd(row))
                values[readValue!(KeyType!U)(map.keys, i)] = readValue!(ValueType!U)(map.values, i);
            return values; // a key given more than once keeps its last value
        }
        else static if (is(U == enum))
        {
            import clickhoused.types.misc : Enum16Column, Enum8Column, NullableColumn;
            import clickhoused.types.string : StringColumn;

            import clickhoused.types.lowcardinality : LowCardinalityColumn;

            Column labels = column; // the column that holds the labels, if any
            if (auto lc = cast(LowCardinalityColumn) labels)
                labels = lc.values;
            if (auto n = cast(NullableColumn) labels)
                labels = n.nested;
            if (cast(Enum8Column) labels !is null || cast(Enum16Column) labels !is null
                    || cast(StringColumn) labels !is null)
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
        else static if (isWideInt!U)
        {
            if (auto wide = cast(WideIntColumn!U) column)
                return wide.data[row];
            // Other integer columns: exact through the decimal text, with a range check
            try
                return U.fromString(column.getString(row));
            catch (ClientException)
                throw new ClientException(
                        "Value of column '" ~ column.name ~ "' (" ~ column.typeName
                        ~ ") does not fit in " ~ U.stringof);
        }
        else static if (is(U == IPv4) || is(U == IPv6))
        {
            static if (is(U == IPv4))
                auto typed = cast(IPv4Column) column;
            else
                auto typed = cast(IPv6Column) column;
            if (typed !is null)
                return typed[row];
            // Other columns: through the text (an IPv4 column gives IPv4-mapped IPv6 addresses)
            try
                return U.fromString(column.getString(row));
            catch (ClientException)
                throw new ClientException(
                        "Value of column '" ~ column.name ~ "' (" ~ column.typeName
                        ~ ") is not an " ~ U.stringof ~ " address");
        }
        else static if (is(U == Decimal))
        {
            Decimal value;
            if (decimalAt(column, row, value))
                return value;
            // Other numeric columns: exact through the decimal text
            try
                return Decimal.fromString(column.getString(row));
            catch (ClientException)
                throw new ClientException(
                        "Value of column '" ~ column.name ~ "' (" ~ column.typeName
                        ~ ") is not a decimal number");
        }
        else static if (is(U == BigInt))
        {
            import std.conv : ConvException;

            try
                return BigInt(column.getString(row));
            catch (ConvException)
                throw new ClientException(
                        "Value of column '" ~ column.name ~ "' (" ~ column.typeName
                        ~ ") is not an integer");
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
        else static if (is(U == Duration))
            return column.getDuration(row);
        else static if (is(U == JSONValue))
        {
            import std.json : JSONException, parseJSON;

            try
                return parseJSON(column.getString(row));
            catch (JSONException e)
                throw new ClientException("Column '" ~ column.name ~ "' (" ~ column.typeName ~ "): not JSON: " ~ e.msg);
        }
        else static if (is(U == TimeOfDay))
        {
            import core.time : hours;

            const span = column.getDuration(row);
            if (span < Duration.zero || span >= 24.hours)
                throw outOfRange!U(column);
            return TimeOfDay(0, 0, 0) + span; // fractional seconds are dropped
        }
        else static if (isTupleValue!U)
        {
            import clickhoused.types.tuple : TupleColumn;

            auto tuple = cast(TupleColumn) column;
            if (tuple is null)
                throw new ClientException("Column '" ~ column.name ~ "' (" ~ column.typeName
                        ~ ") is not a Tuple column, which " ~ U.stringof ~ " needs");
            const positions = tuple.fieldPositions(columnNames!U, U.stringof);
            U value;
            size_t k;
            static foreach (i; 0 .. U.tupleof.length)
            {
                static if (!hasUDA!(U.tupleof[i], IgnoreField))
                    setField(value.tupleof[i], readValue!(typeof(U.tupleof[i]))(tuple.elements[positions[k++]], row));
            }
            return value;
        }
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
    private FastFields!T fast; // typed access to the columns that match their fields exactly
    private size_t row;
    private T current;
    private bool loaded;

    package this(QueryResult result) @safe
    {
        result_ = result;
    }

    /// Whether all rows have been consumed. Reads from the network if needed.
    @property bool empty()
    {
        load();
        return !loaded;
    }

    /// The current row.
    @property T front()
    {
        load();
        assert(loaded, "RowRange.front called on an empty range");
        return current;
    }

    /// Moves to the next row.
    void popFront()
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

    private void load()
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
            {
                bound = bindColumns!T(block);
                bindFast!T(fast, bound);
            }
            catch (ClientException e)
            {
                result_.close(); // free the connection: the rest of the result is useless
                block = null;
                throw e;
            }
            row = 0;
        }
        current = readStruct!T(bound, fast, row);
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
package T readStruct(T)(Column[] bound, size_t row)
{
    FastFields!T fast;
    return readStruct!T(bound, fast, row);
}

/// ditto, taking the fields that `fast` has a typed column for straight from it.
package T readStruct(T)(Column[] bound, ref FastFields!T fast, size_t row)
{
    T value;
    static foreach (k, i; mappedFields!T)
    {
        static assert(isMappableValue!(typeof(T.tupleof[i])), T.stringof ~ "." ~ __traits(identifier,
                T.tupleof[i]) ~ ": fields of type " ~ typeof(T.tupleof[i]).stringof ~ " cannot be mapped");
        if (!fast[k].read(row, value.tupleof[i]))
            setField(value.tupleof[i], readValue!(typeof(T.tupleof[i]))(bound[k], row));
    }
    return value;
}

/++
Typed access to the column of a field of type `F`, when the column has
exactly the matching type (`long` and `Int64`, `string` and `String`,
`SysTime` and `DateTime64`, ...): values are read from its array without the
checks and conversions of `readValue`.
+/
package struct FastField(F)
{
    import clickhoused.types.datetime : Date32Column, DateColumn, DateTime64Column, DateTimeColumn;
    import clickhoused.types.misc : UUIDColumn;
    import clickhoused.types.numeric : BoolColumn, NumericColumn;
    import clickhoused.types.string : StringColumn;

    private alias U = Unqual!F;
    static if (isIntegral!U || isFloatingPoint!U)
    {
        private NumericColumn!U column;

        bool bind(Column c) @safe pure nothrow
        {
            column = cast(NumericColumn!U) c;
            return column !is null;
        }

        bool read(size_t row, ref F target) @safe
        {
            if (column is null)
                return false;
            target = column.data[row];
            return true;
        }
    }
    else static if (is(U == bool) || is(U == string) || is(U == UUID))
    {
        static if (is(U == bool))
            private BoolColumn column;
        else static if (is(U == string))
            private StringColumn column;
        else
            private UUIDColumn column;

        bool bind(Column c) @safe pure nothrow
        {
            column = cast(typeof(column)) c;
            return column !is null;
        }

        bool read(size_t row, ref F target) @safe
        {
            if (column is null)
                return false;
            target = column.data[row];
            return true;
        }
    }
    else static if (is(U == SysTime) || is(U == Date))
    {
        static if (is(U == SysTime))
        {
            private DateTime64Column wide;
            private DateTimeColumn narrow;
        }
        else
        {
            private Date32Column wide;
            private DateColumn narrow;
        }

        bool bind(Column c) @safe pure nothrow
        {
            wide = cast(typeof(wide)) c;
            narrow = cast(typeof(narrow)) c;
            return wide !is null || narrow !is null;
        }

        bool read(size_t row, ref F target) @safe
        {
            if (wide !is null)
                target = wide[row];
            else if (narrow !is null)
                target = narrow[row];
            else
                return false;
            return true;
        }
    }
    else
    {
        bool bind(Column) @safe pure nothrow
        {
            return false;
        }

        bool read(size_t, ref F) @safe pure nothrow
        {
            return false;
        }
    }
}

/// A `FastField` for each mapped field of `T`.
package template FastFields(T)
{
    import std.meta : staticMap;
    import std.typecons : Tuple;

    private template FieldType(size_t i)
    {
        alias FieldType = FastField!(typeof(T.tupleof[i]));
    }

    alias FastFields = Tuple!(staticMap!(FieldType, mappedFields!T));
}

/// Binds the typed columns of `fast` to `bound` (the columns of a block, from `bindColumns`).
package void bindFast(T)(ref FastFields!T fast, Column[] bound) @safe
{
    static foreach (k; 0 .. mappedFields!T.length)
        fast[k].bind(bound[k]);
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

/// `target = source`.
private void setField(T)(ref T target, T source)
{
    target = source;
}

/// ditto: assigning a `std.variant.Variant` is memory-safe, but std.variant is not annotated @safe.
private void setField(ref Variant target, Variant source) @trusted
{
    target = source;
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

// 128/256-bit integers and BigInt to and from columns
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.insert : appendValue;
    import clickhoused.types.factory : createColumn;
    import clickhoused.types.wideint : Int128, Int256, UInt128;

    auto c = createColumn("i", "Int128");
    appendValue(c, Int128.min);
    appendValue(c, BigInt("-42"));
    appendValue(c, 7);
    assert(readValue!Int128(c, 0) == Int128.min);
    assert(readValue!BigInt(c, 0) == BigInt("-170141183460469231731687303715884105728"));
    assert(readValue!Int256(c, 1) == Int256(-42) && readValue!long(c, 2) == 7);
    assertThrown!ClientException(readValue!UInt128(c, 1)); // negative
    assertThrown!ClientException(readValue!long(c, 0)); // too big
    assertThrown!ClientException(appendValue(c, BigInt(1) << 127)); // out of range
    assert(c.length == 3);

    // Other integer columns read into and from the wide types
    auto u64 = createColumn("u", "UInt64");
    appendValue(u64, UInt128(ulong.max));
    assert(readValue!UInt128(u64, 0) == UInt128(ulong.max) && readValue!BigInt(u64, 0) == BigInt(ulong.max));
    assertThrown!ClientException(appendValue(u64, UInt128.max));

    auto nullable = createColumn("n", "Nullable(Int256)");
    appendValue(nullable, Nullable!Int256(Int256.max));
    appendValue(nullable, Nullable!Int256.init);
    assert(readValue!(Nullable!Int256)(nullable, 0).get == Int256.max);
    assert(readValue!(Nullable!Int256)(nullable, 1).isNull);
}

// Decimal values to and from columns
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.insert : appendValue;
    import clickhoused.types.decimal : Decimal;
    import clickhoused.types.factory : createColumn;

    auto c = createColumn("p", "Decimal(9, 2)");
    appendValue(c, Decimal.fromString("1.239")); // truncated to the scale
    appendValue(c, "-0.5");
    appendValue(c, 3.25);
    appendValue(c, 7);
    assert(readValue!Decimal(c, 0) == Decimal.fromString("1.23") && readValue!Decimal(c, 0).scale == 2);
    assert(readValue!string(c, 1) == "-0.5" && readValue!double(c, 2) == 3.25 && readValue!long(c, 3) == 7);
    assertThrown!ClientException(appendValue(c, Decimal.fromString("12345678.9")));
    assert(c.length == 4);

    // Decimals from and to other numeric columns
    auto f = createColumn("f", "Float64");
    appendValue(f, Decimal.fromString("2.5"));
    assert(readValue!Decimal(f, 0) == Decimal.fromString("2.5"));
    auto i = createColumn("i", "Int32");
    appendValue(i, Decimal.fromString("42.00"));
    assertThrown!ClientException(appendValue(i, Decimal.fromString("4.2")));
    assert(readValue!Decimal(i, 0) == Decimal.fromString("42"));

    auto n = createColumn("n", "Nullable(Decimal(38, 5))");
    appendValue(n, Nullable!Decimal.init);
    appendValue(n, Nullable!Decimal(Decimal.fromString("-1.00001")));
    assert(readValue!(Nullable!Decimal)(n, 0).isNull);
    assert(readValue!(Nullable!Decimal)(n, 1).get.toString() == "-1.00001");
}

// IP addresses to and from columns
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.insert : appendValue;
    import clickhoused.types.factory : createColumn;

    auto v4 = createColumn("a", "IPv4");
    appendValue(v4, IPv4.fromString("10.0.0.1"));
    appendValue(v4, "192.168.1.1");
    assert(readValue!IPv4(v4, 0) == IPv4(0x0a00_0001) && readValue!string(v4, 1) == "192.168.1.1");
    assert(readValue!uint(v4, 0) == 0x0a00_0001);
    assert(readValue!IPv6(v4, 0).toString() == "::ffff:10.0.0.1"); // mapped

    auto v6 = createColumn("b", "Nullable(IPv6)");
    appendValue(v6, IPv6.fromString("::1"));
    appendValue(v6, IPv4.fromString("1.2.3.4")); // stored IPv4-mapped
    appendValue(v6, null);
    assert(readValue!IPv6(v6, 0).toString() == "::1" && readValue!string(v6, 1) == "::ffff:1.2.3.4");
    assert(readValue!(Nullable!IPv6)(v6, 2).isNull);
    assertThrown!ClientException(readValue!IPv4(v6, 0));
    assertThrown!ClientException(appendValue(createColumn("c", "IPv4"), IPv6.fromString("::1")));
}

// Structs and std.typecons.Tuple to and from Tuple columns
@safe unittest
{
    import std.exception : assertThrown;
    import std.typecons : Tuple, tuple;
    import clickhoused.insert : appendValue;
    import clickhoused.types.factory : createColumn;
    import clickhoused.types.tuple : TupleColumn;

    static struct Point
    {
        double x;
        double y;
    }

    static struct Named
    {
        @column("full name") string name; // element names, in any order
        ulong id;
        @ignore int cache;
    }

    auto points = createColumn("p", "Tuple(Float64, Float64)"); // no names: by position
    appendValue(points, Point(1.5, -2));
    appendValue(points, tuple(3.0, 4.0));
    assert(points.getString(0) == "(1.5,-2)" && readValue!Point(points, 1) == Point(3, 4));
    assert(readValue!(Tuple!(double, double))(points, 0) == tuple(1.5, -2.0));

    auto named = createColumn("n", "Tuple(id UInt64, `full name` String)"); // names: by name
    appendValue(named, Named("Ann", 7));
    assert(named.getString(0) == "(7,'Ann')");
    const back = readValue!Named(named, 0);
    assert(back.name == "Ann" && back.id == 7);

    // Nested in arrays and Nullable fields; a value that doesn't fit leaves nothing behind
    auto list = createColumn("l", "Array(Tuple(String, Nullable(Int32)))");
    appendValue(list, [tuple("a", Nullable!int(1)), tuple("b", Nullable!int.init)]);
    assert(list.getString(0) == "[('a',1),('b',NULL)]");
    assertThrown!ClientException(appendValue(points, tuple("x", 1.0))); // not a number
    assert(points.length == 2 && (cast(TupleColumn) points).elements[0].length == 2);
    assertThrown!ClientException(appendValue(points, tuple(1.0, 2.0, 3.0))); // three fields
    auto text = createColumn("s", "String");
    appendValue(text, "x");
    assertThrown!ClientException(readValue!Point(text, 0));
}

// Associative arrays and arrays of (key, value) tuples to and from Map columns
@safe unittest
{
    import std.exception : assertThrown;
    import std.typecons : Tuple, tuple;
    import clickhoused.insert : appendValue;
    import clickhoused.types.factory : createColumn;
    import clickhoused.types.map : MapColumn;

    auto c = createColumn("m", "Map(String, Nullable(Int64))");
    appendValue(c, ["a": Nullable!long(1)]);
    appendValue(c, [tuple("x", Nullable!long.init), tuple("x", Nullable!long(2))]); // ordered, duplicate key
    appendValue(c, cast(long[string]) null);
    assert(c.getString(0) == "{'a':1}" && c.getString(1) == "{'x':NULL,'x':2}" && c.getString(2) == "{}");
    assert(readValue!(Nullable!long[string])(c, 0)["a"].get == 1);
    assert(readValue!(Nullable!long[string])(c, 1)["x"].get == 2); // the last value of a repeated key
    assert(readValue!(Tuple!(string, Nullable!long)[])(c, 1).length == 2);
    assert(readValue!string(c, 0) == "{'a':1}");
    assertThrown!ClientException(appendValue(c, ["b": "not a number"]));
    assert(c.length == 3 && (cast(MapColumn) c).keys.length == 3); // the failed row left no trace

    auto nested = createColumn("n", "Map(UInt8, Map(String, Array(UInt8)))");
    appendValue(nested, [ubyte(1): ["k": [ubyte(2), 3]]]);
    assert(nested.getString(0) == "{1:{'k':[2,3]}}");
    assert(readValue!(ubyte[][string][ubyte])(nested, 0)[1]["k"] == [2, 3]);
    auto text = createColumn("s", "String");
    appendValue(text, "x");
    assertThrown!ClientException(readValue!(long[string])(text, 0));
}

@safe unittest
{
    import core.time : hours, minutes, msecs, seconds;
    import std.exception : assertThrown;
    import clickhoused.insert : appendValue;
    import clickhoused.types.factory : createColumn;

    // Time and Time64: Duration for any value, TimeOfDay from 00:00:00 to 23:59:59
    static struct Shift
    {
        TimeOfDay start;
        Duration length;
        Nullable!Duration pause;
    }

    auto t = createColumn("t", "Time");
    appendValue(t, TimeOfDay(9, 30, 0));
    appendValue(t, -90.minutes);
    appendValue(t, 25.hours);
    assert(t.getString(0) == "09:30:00" && t.getString(1) == "-01:30:00" && t.getString(2) == "25:00:00");
    assert(readValue!TimeOfDay(t, 0) == TimeOfDay(9, 30, 0) && readValue!Duration(t, 1) == -90.minutes);
    assertThrown!ClientException(readValue!TimeOfDay(t, 1));
    assertThrown!ClientException(readValue!TimeOfDay(t, 2));
    assertThrown!ClientException(appendValue(t, 1000.hours));
    assert(t.length == 3);

    auto t3 = createColumn("t", "Nullable(Time64(3))");
    appendValue(t3, 1500.msecs);
    appendValue(t3, Nullable!Duration.init);
    appendValue(t3, TimeOfDay(23, 59, 59));
    assert(t3.getString(0) == "00:00:01.500" && t3.isNull(1) && t3.getString(2) == "23:59:59.000");
    assert(readValue!(Nullable!Duration)(t3, 0).get == 1500.msecs && readValue!(Nullable!Duration)(t3, 1).isNull);
    assert(readValue!TimeOfDay(t3, 0) == TimeOfDay(0, 0, 1)); // fraction dropped
    assert(isMappableValue!Shift && !isTupleValue!Duration && !isTupleValue!TimeOfDay);
    auto a = createColumn("a", "Array(Time)");
    appendValue(a, [1.seconds, -2.seconds]);
    assert(a.getString(0) == "['00:00:01','-00:00:02']" && readValue!(Duration[])(a, 0) == [
        1.seconds, -2.seconds
    ]);
}

@system unittest
{
    import std.exception : assertThrown;
    import clickhoused.insert : appendValue;
    import clickhoused.types.factory : createColumn;

    // std.variant.Variant: the held value of any column, NULL as an empty Variant
    static struct Row
    {
        uint id;
        Variant v;
    }

    auto c = createColumn("v", "Variant(Date, Int64, String)");
    appendValue(c, Variant(5));
    appendValue(c, Variant("x"));
    appendValue(c, Variant.init);
    appendValue(c, Variant(Date(2020, 1, 2)));
    assert(c.getString(0) == "5" && c.getString(1) == "x" && c.isNull(2) && c.getString(3) == "2020-01-02");
    assert(readValue!Variant(c, 0).get!long == 5 && !readValue!Variant(c, 2).hasValue);
    auto n = createColumn("n", "Nullable(UInt8)");
    appendValue(n, 7);
    appendValue(n, null);
    assert(readValue!Variant(n, 0).get!ubyte == 7 && !readValue!Variant(n, 1).hasValue);
    assertThrown!ClientException(appendValue(c, Variant([1, 2])));
    assert(c.length == 4 && isMappableValue!Row && !isTupleValue!Variant);
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.insert : appendValue;
    import clickhoused.types.decimal : Decimal;
    import clickhoused.types.factory : createColumn;
    import clickhoused.types.ip : IPv4;

    // Values without a typed append choose the matching Variant alternative, not String
    static struct Pair
    {
        ubyte a;
        string b;
    }

    auto c = createColumn("v", "Variant(Array(UInt8), Decimal(9, 2), IPv4, Map(String, UInt8), String, "
            ~ "Tuple(a UInt8, b String))");
    appendValue(c, [ubyte(1), 2]);
    appendValue(c, Decimal.fromString("1.5"));
    appendValue(c, IPv4(0x01020304));
    appendValue(c, ["k": ubyte(7)]);
    appendValue(c, Pair(3, "x"));
    appendValue(c, "text");
    const string[] expected = ["[1,2]", "1.5", "1.2.3.4", "{'k':7}", "(3,'x')", "text"];
    foreach (i, e; expected)
        assert(c.getString(i) == e, c.getString(i));
    assert(readValue!(ubyte[])(c, 0) == [1, 2] && readValue!Pair(c, 4) == Pair(3, "x"));
    assertThrown!ClientException(appendValue(c, [1.5]));
    assert(c.length == 6);
}

@safe unittest
{
    import std.exception : assertThrown;
    import std.typecons : tuple;
    import clickhoused.insert : appendValue;
    import clickhoused.types.decimal : Decimal;
    import clickhoused.types.dynamic : DynamicColumn;
    import clickhoused.types.factory : createColumn;
    import clickhoused.types.ip : IPv4;

    // Dynamic: the type comes from the D value
    static struct Pair
    {
        ubyte a;
        @column("b c") string b;
    }

    auto d = cast(DynamicColumn) createColumn("d", "Dynamic");
    appendValue(d, 5);
    appendValue(d, [1L, 2]);
    appendValue(d, ["k": [1.5]]);
    appendValue(d, Pair(3, "x"));
    appendValue(d, tuple(1, "y"));
    appendValue(d, Decimal.fromString("-12.345"));
    appendValue(d, IPv4(0x01020304));
    appendValue(d, [Nullable!int(1), Nullable!int.init]);
    appendValue(d, null);
    string[] kinds;
    foreach (row; 0 .. 8) // the last row is NULL
        kinds ~= d.dynamicTypeName(row) ~ " " ~ d.getString(row);
    assert(kinds == [
        "Int64 5", "Array(Int64) [1,2]", "Map(String, Array(Float64)) {'k':[1.5]}",
        "Tuple(a UInt64, `b c` String) (3,'x')", "Tuple(Int64, String) (1,'y')",
        "Decimal(9, 3) -12.345",
        "IPv4 1.2.3.4", "Array(Nullable(Int64)) [1,NULL]"
    ], kinds[3]);
    assert(d.isNull(8));
    assert(readValue!(long[])(d, 1) == [1, 2] && readValue!Pair(d, 3) == Pair(3, "x"));
    assertThrown!ClientException(readValue!long(d, 8));
}

@safe unittest
{
    import std.exception : assertThrown;
    import std.json : parseJSON;
    import clickhoused.insert : appendValue;
    import clickhoused.types.dynamic : DynamicColumn;
    import clickhoused.types.factory : createColumn;
    import clickhoused.types.variant : VariantColumn;

    // std.json.JSONValue: JSON columns (and JSON text elsewhere), also inside Variant and Dynamic
    static struct Doc
    {
        uint id;
        JSONValue body;
    }

    auto j = createColumn("j", "JSON");
    appendValue(j, parseJSON(`{"a":[1,2]}`));
    assert(j.getString(0) == `{"a":[1,2]}` && readValue!JSONValue(j, 0)["a"][1].integer == 2);
    auto s = createColumn("s", "String");
    appendValue(s, "not json");
    assertThrown!ClientException(readValue!JSONValue(s, 0));
    assert(isMappableValue!Doc && !isTupleValue!JSONValue);

    auto v = createColumn("v", "Variant(JSON, String)");
    appendValue(v, parseJSON(`{"b":1}`));
    assert((cast(VariantColumn) v).variantTypeName(0) == "JSON");
    auto d = cast(DynamicColumn) createColumn("d", "Dynamic");
    appendValue(d, parseJSON(`{"c":true}`));
    assert(d.dynamicTypeName(0) == "JSON" && d.getString(0) == `{"c":true}`);
}

@safe unittest
{
    import std.datetime.timezone : UTC;
    import clickhoused.insert : appendValue;
    import clickhoused.types.factory : createColumn;

    // Fields read through typed columns (exact matches) and through readValue (conversions) give the same values
    static struct Row
    {
        long a;
        int b;
        double c;
        bool d;
        string e;
        SysTime f;
        Date g;
        UUID h;
        ubyte i;
    }

    auto exact = new Block;
    auto converting = new Block;
    const string[] exactTypes = [
        "Int64", "Int32", "Float64", "Bool", "String", "DateTime64(3, 'UTC')", "Date32", "UUID",
        "UInt8"
    ];
    const string[] otherTypes = [
        "UInt8", "Nullable(Int16)", "Float32", "UInt8", "LowCardinality(String)", "DateTime('UTC')",
        "Date",
        "Nullable(UUID)", "Int64"
    ];
    const names = columnNames!Row;
    foreach (k, name; names)
    {
        exact.columns ~= createColumn(name, exactTypes[k]);
        converting.columns ~= createColumn(name, otherTypes[k]);
    }
    const when = SysTime.fromUnixTime(1_600_000_000, UTC());
    const id = UUID("00112233-4455-6677-8899-aabbccddeeff");
    foreach (block; [exact, converting])
    {
        foreach (k; 0 .. names.length) switch (k)
        {
        case 0, 1, 8:
            appendValue(block.columns[k], 7);
            break;
        case 2:
            appendValue(block.columns[k], 1.5);
            break;
        case 3:
            appendValue(block.columns[k], true);
            break;
        case 4:
            appendValue(block.columns[k], "x");
            break;
        case 5:
            appendValue(block.columns[k], when);
            break;
        case 6:
            appendValue(block.columns[k], Date(2020, 1, 2));
            break;
        default:
            appendValue(block.columns[k], id);
        }
        block.rows = 1;
    }
    const expected = Row(7, 7, 1.5, true, "x", when, Date(2020, 1, 2), id, 7);
    foreach (block; [exact, converting])
    {
        auto bound = bindColumns!Row(block);
        FastFields!Row fast;
        bindFast!Row(fast, bound);
        assert(readStruct!Row(bound, fast, 0) == expected);
        assert(readStruct!Row(bound, 0) == expected);
    }
    FastFields!Row fast;
    bindFast!Row(fast, bindColumns!Row(exact));
    assert(fast[0].column !is null && fast[4].column !is null && fast[5].wide !is null);
    bindFast!Row(fast, bindColumns!Row(converting));
    assert(fast[0].column is null && fast[5].narrow !is null && fast[8].column is null);
}
