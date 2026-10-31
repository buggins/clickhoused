/++
Creating columns from ClickHouse type names.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.factory;

import clickhoused.exception : ClientException, ProtocolException;
import clickhoused.types.array : ArrayColumn;
import clickhoused.types.column : Column;
import clickhoused.types.datetime;
import clickhoused.types.decimal;
import clickhoused.types.lowcardinality : LowCardinalityColumn;
import clickhoused.types.misc;
import clickhoused.types.numeric;
import clickhoused.types.parser : TypeArgKind, TypeNode, parseType;
import clickhoused.types.string;
import clickhoused.types.wideint;

/++
Creates an empty column for the ClickHouse type `typeName`.

Params:
    name = column name.
    typeName = ClickHouse type name, e.g. `"Nullable(DateTime('UTC'))"`.
    defaultTimezone = timezone for `DateTime` and `DateTime64` types without an
        explicit timezone; normally the server timezone.

Throws:
    `ClientException` if the type is not supported by this version of clickhoused;
    `ProtocolException` if `typeName` is not a valid type name.
+/
Column createColumn(string name, string typeName, string defaultTimezone = null) @safe
{
    return createColumn(name, typeName, parseType(typeName), defaultTimezone);
}

///
@safe unittest
{
    const c = createColumn("n", "Nullable(DateTime('UTC'))");
    const nullable = cast(const NullableColumn) c;
    assert(nullable !is null);
    assert((cast(const DateTimeColumn) nullable.nested).timezone == "UTC");
}

private Column createColumn(string name, string typeName, const TypeNode type, string defaultTimezone) @safe
{
    import std.conv : to;

    ProtocolException invalid()
    {
        return new ProtocolException("Invalid type name '" ~ typeName ~ "'");
    }

    // The optional timezone argument at position `index`, or the default
    string timezoneArg(size_t index)
    {
        if (type.args.length <= index)
            return defaultTimezone;
        if (type.args[index].kind != TypeArgKind.text)
            throw invalid();
        return type.args[index].text;
    }

    T[string] enumElements(T)()
    {
        T[string] elements;
        foreach (ref arg; type.args)
        {
            if (arg.kind != TypeArgKind.enumValue || arg.number < T.min || arg.number > T.max)
                throw invalid();
            elements[arg.text] = cast(T) arg.number;
        }
        return elements;
    }

    // Decimal(P, S), or Decimal32(S) ... Decimal256(S) with the largest precision of the width
    Column decimalColumn()
    {
        uint number(size_t i)
        {
            if (type.args[i].kind != TypeArgKind.number || type.args[i].number < 0 || type.args[i].number > 76)
                throw invalid();
            return cast(uint) type.args[i].number;
        }

        uint precision, scale;
        if (type.name == "Decimal")
        {
            if (type.args.length != 2)
                throw invalid();
            precision = number(0);
            scale = number(1);
        }
        else
        {
            if (type.args.length != 1)
                throw invalid();
            precision = type.name == "Decimal32" ? 9 : type.name == "Decimal64" ? 18 : type.name == "Decimal128" ? 38
                : 76;
            scale = number(0);
        }
        if (precision == 0 || scale > precision)
            throw invalid();
        if (precision <= 9)
            return new Decimal32Column(name, typeName, precision, scale);
        if (precision <= 18)
            return new Decimal64Column(name, typeName, precision, scale);
        if (precision <= 38)
            return new Decimal128Column(name, typeName, precision, scale);
        return new Decimal256Column(name, typeName, precision, scale);
    }

    switch (type.name)
    {
    case "UInt8":
        return new UInt8Column(name, typeName);
    case "UInt16":
        return new UInt16Column(name, typeName);
    case "UInt32":
        return new UInt32Column(name, typeName);
    case "UInt64":
        return new UInt64Column(name, typeName);
    case "Int8":
        return new Int8Column(name, typeName);
    case "Int16":
        return new Int16Column(name, typeName);
    case "Int32":
        return new Int32Column(name, typeName);
    case "Int64":
        return new Int64Column(name, typeName);
    case "Int128":
        return new Int128Column(name, typeName);
    case "UInt128":
        return new UInt128Column(name, typeName);
    case "Int256":
        return new Int256Column(name, typeName);
    case "UInt256":
        return new UInt256Column(name, typeName);
    case "Decimal":
    case "Decimal32":
    case "Decimal64":
    case "Decimal128":
    case "Decimal256":
        return decimalColumn();
    case "Float32":
        return new Float32Column(name, typeName);
    case "Float64":
        return new Float64Column(name, typeName);
    case "Bool":
        return new BoolColumn(name, typeName);
    case "String":
        return new StringColumn(name, typeName);
    case "FixedString":
        if (type.args.length != 1 || type.args[0].kind != TypeArgKind.number || type.args[0].number <= 0)
            throw invalid();
        return new FixedStringColumn(name, type.args[0].number.to!size_t, typeName);
    case "Date":
        return new DateColumn(name, typeName);
    case "Date32":
        return new Date32Column(name, typeName);
    case "DateTime":
        if (type.args.length > 1)
            throw invalid();
        return new DateTimeColumn(name, typeName, timezoneArg(0));
    case "DateTime64":
        if (type.args.length < 1 || type.args.length > 2 || type.args[0].kind != TypeArgKind.number
                || type.args[0].number < 0 || type.args[0].number > 9)
            throw invalid();
        return new DateTime64Column(name, cast(uint) type.args[0].number, typeName, timezoneArg(1));
    case "UUID":
        return new UUIDColumn(name, typeName);
    case "Enum8":
        return new Enum8Column(name, typeName, enumElements!byte());
    case "Enum16":
        return new Enum16Column(name, typeName, enumElements!short());
    case "Nullable":
        if (type.args.length != 1 || type.args[0].kind != TypeArgKind.type)
            throw invalid();
        const nestedType = type.args[0].type;
        if (nestedType.name == "Nullable" || nestedType.name == "Array" || nestedType.name == "LowCardinality")
            throw invalid();
        auto nested = createColumn(name, nestedType.toString(), nestedType, defaultTimezone);
        return new NullableColumn(name, typeName, nested);
    case "Array":
        if (type.args.length != 1 || type.args[0].kind != TypeArgKind.type)
            throw invalid();
        const elementType = type.args[0].type;
        auto elements = createColumn(name, elementType.toString(), elementType, defaultTimezone);
        return new ArrayColumn(name, typeName, elements);
    case "LowCardinality":
        if (type.args.length != 1 || type.args[0].kind != TypeArgKind.type)
            throw invalid();
        const innerType = type.args[0].type;
        if (innerType.name == "LowCardinality" || innerType.name == "Array")
            throw invalid();
        // The dictionary holds the inner type without Nullable: NULL is index 0
        const keyType = innerType.name == "Nullable" ? innerType.args[0].type : innerType;
        Column newKeys() @safe
        {
            return createColumn(name, keyType.toString(), keyType, defaultTimezone);
        }

        auto values = createColumn(name, innerType.toString(), innerType, defaultTimezone);
        newKeys(); // fails now, not when the first block arrives, if the key type is unsupported
        return new LowCardinalityColumn(name, typeName, values, &newKeys);
    case "Nothing":
        return new NothingColumn(name, typeName);
    default:
        throw new ClientException("Unsupported column type '" ~ typeName ~ "' (column '" ~ name ~ "')");
    }
}

@safe unittest
{
    import std.exception : assertThrown;

    assert(cast(UInt32Column) createColumn("n", "UInt32") !is null);
    assert((cast(FixedStringColumn) createColumn("s", "FixedString(3)")).width == 3);
    assert((cast(DateTimeColumn) createColumn("t", "DateTime", "Europe/Lisbon")).timezone == "Europe/Lisbon");
    auto t64 = cast(DateTime64Column) createColumn("t", "DateTime64(6, 'Asia/Tokyo')", "UTC");
    assert(t64.precision == 6 && t64.timezone == "Asia/Tokyo");
    auto e = cast(Enum16Column) createColumn("e", "Enum16('x' = -300, 'y' = 300)");
    assert(e.labels[-300] == "x");
    assert(cast(NothingColumn)(cast(NullableColumn) createColumn("n", "Nullable(Nothing)")).nested !is null);

    assert(cast(UInt8Column)(cast(ArrayColumn) createColumn("a", "Array(UInt8)")).elements !is null);
    assertThrown!ClientException(createColumn("x", "Map(String, UInt8)"));
    assertThrown!ClientException(createColumn("x", "Array(Map(String, UInt8))"));
    assertThrown!ProtocolException(createColumn("x", "Nullable(Array(UInt8))"));
    assertThrown!ProtocolException(createColumn("x", "Array(UInt8, UInt8)"));
    assert(cast(StringColumn)(cast(LowCardinalityColumn) createColumn("l", "LowCardinality(String)")).values !is null);
    assertThrown!ProtocolException(createColumn("x", "LowCardinality(Array(UInt8))"));
    assertThrown!ProtocolException(createColumn("x", "Nullable(LowCardinality(String))"));
    auto d = cast(Decimal128Column) createColumn("d", "Decimal(20, 3)");
    assert(d.precision == 20 && d.scale == 3);
    assert((cast(Decimal64Column) createColumn("d", "Decimal64(4)")).precision == 18);
    assert(cast(Decimal256Column) createColumn("d", "Decimal256(0)") !is null);
    assertThrown!ProtocolException(createColumn("x", "Decimal(5, 6)"));
    assertThrown!ProtocolException(createColumn("x", "Decimal(77, 0)"));
    assertThrown!ProtocolException(createColumn("x", "Decimal(10)"));
    assertThrown!ProtocolException(createColumn("x", "FixedString(0)"));
    assertThrown!ProtocolException(createColumn("x", "DateTime64(10)"));
    assertThrown!ProtocolException(createColumn("x", "Enum8('a' = 200)"));
    assertThrown!ProtocolException(createColumn("x", "Nullable(Nullable(UInt8))"));
}

@safe unittest
{
    import clickhoused.io.buffer : BufferedReader, BufferedWriter;
    import clickhoused.io.mock : MockTransport;

    // Native-format round trip for every supported column type
    static immutable string[] types = [
        "Int64", "Float64", "Bool", "String", "FixedString(2)", "Date", "Date32", "DateTime('UTC')",
        "DateTime64(3, 'UTC')", "UUID", "Enum8('a' = 1, 'b' = 2)", "Nullable(String)",
        "Nullable(Nothing)", "Array(Int64)", "Array(Nullable(String))", "Array(Array(Date))",
        "Array(Nothing)", "LowCardinality(String)", "LowCardinality(Nullable(String))",
        "Array(LowCardinality(String))", "LowCardinality(FixedString(2))", "LowCardinality(Date)",
        "Int128", "UInt128", "Int256", "UInt256", "Array(Nullable(Int256))",
        "Decimal(9, 2)", "Decimal(18, 0)", "Decimal(38, 10)", "Decimal(76, 76)",
        "Nullable(Decimal(20, 3))",
    ];
    auto t = new MockTransport;
    auto w = new BufferedWriter(t);
    Column[] written;
    foreach (typeName; types)
    {
        auto c = createColumn("c", typeName);
        fill(c);
        c.writeStatePrefix(w);
        c.writeData(w);
        written ~= c;
    }
    w.flush();
    t.feed(t.written);
    auto r = new BufferedReader(t);
    foreach (i, typeName; types)
    {
        auto c = createColumn("c", typeName);
        c.readStatePrefix(r);
        c.readData(r, 2);
        foreach (row; 0 .. 2)
        {
            assert(c.isNull(row) == written[i].isNull(row), typeName);
            if (!c.isNull(row))
                assert(c.getString(row) == written[i].getString(row), typeName);
        }
    }
    assert(t.remaining == 0);
}

version (unittest)
{
    /// Fills a test column with two rows of non-default values.
    private void fill(Column c) @safe
    {
        import std.uuid : UUID;

        if (auto n = cast(NullableColumn) c)
        {
            fill(n.nested);
            n.nulls = [false, true];
        }
        else if (auto lc = cast(LowCardinalityColumn) c)
            fill(lc.values);
        else if (auto a = cast(ArrayColumn) c)
        {
            if (cast(NothingColumn) a.elements)
                a.offsets = [0, 0]; // Array(Nothing) holds only empty arrays
            else
            {
                fill(a.elements); // two elements: [] and [both]
                a.offsets = [0, 2];
            }
        }
        else if (auto x = cast(Int64Column) c)
            x.data = [long.min, 42];
        else if (auto x = cast(Decimal32Column) c)
            x.data = [-999_999_999, 150];
        else if (auto x = cast(Decimal64Column) c)
            x.data = [long.min + 1, 0];
        else if (auto x = cast(Decimal128Column) c)
            x.data = [Int128.fromString("-99999999999999999999999999999999999999"), Int128(5)];
        else if (auto x = cast(Decimal256Column) c)
            x.data = [
            Int256.fromString("1"),
            Int256.fromString("-" ~ "9999999999999999999999999999999999999999999999999999999999999999999999999999")
        ];
        else if (auto x = cast(Int128Column) c)
            x.data = [Int128.min, Int128(-1)];
        else if (auto x = cast(UInt128Column) c)
            x.data = [UInt128.max, UInt128(0)];
        else if (auto x = cast(Int256Column) c)
            x.data = [Int256.min, Int256.max];
        else if (auto x = cast(UInt256Column) c)
            x.data = [UInt256.max, UInt256(7)];
        else if (auto x = cast(Float64Column) c)
            x.data = [-0.5, 1e300];
        else if (auto x = cast(BoolColumn) c)
            x.data = [true, false];
        else if (auto x = cast(StringColumn) c)
            x.data = ["", "text"];
        else if (auto x = cast(FixedStringColumn) c)
            x.bytes = ['a', 0, 'b', 'c'];
        else if (auto x = cast(DateColumn) c)
            x.data = [0, 65_535];
        else if (auto x = cast(Date32Column) c)
            x.data = [-25_567, 120_529];
        else if (auto x = cast(DateTimeColumn) c)
            x.data = [0, uint.max];
        else if (auto x = cast(DateTime64Column) c)
            x.data = [-1, 1_761_741_296_789];
        else if (auto x = cast(UUIDColumn) c)
            x.data = [UUID("00112233-4455-6677-8899-aabbccddeeff"), UUID.init];
        else if (auto x = cast(Enum8Column) c)
            x.data = [1, 2];
        else if (auto x = cast(NothingColumn) c)
            x.rows = 2;
        else
            assert(0, "no test data for " ~ c.typeName);
    }
}
