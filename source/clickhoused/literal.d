/++
Formatting D values as ClickHouse SQL literals.

Prefer server-side query parameters (`{name:Type}` placeholders, passed to
`Connection.query`), which never mix data into SQL text. `formatLiteral` is
for the places parameters cannot be used, such as some DDL statements.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.literal;

import std.bigint : BigInt, toDecimalString;
import std.datetime.date : Date;
import std.datetime.systime : SysTime;
import std.traits : isArray, isFloatingPoint, isIntegral, isSomeString, Unqual;
import std.typecons : Nullable;
import std.uuid : UUID;

import clickhoused.types.wideint : Int128, UInt256, isWideInt;

/++
Formats `value` as a SQL literal:
$(UL
    $(LI integers and booleans as is; floating-point numbers with full precision, `inf`, `-inf`, `nan`;)
    $(LI strings and `ubyte[]` in single quotes, with quotes, backslashes and control characters escaped;)
    $(LI `Date` as `toDate32('YYYY-MM-DD')` (years 1900 to 2299);)
    $(LI `SysTime` as `toDateTime64('…', 7, 'UTC')`, the exact point in time;)
    $(LI `UUID` as `toUUID('…')`; D enums as their quoted member name;)
    $(LI `Int128`, `UInt128`, `Int256`, `UInt256` as `toInt128('…')` and so on, and
        `std.bigint.BigInt` as `toInt256('…')`: ClickHouse would read a plain literal
        beyond 64 bits as `Float64`;)
    $(LI `null` and empty `Nullable` as `NULL`; other arrays as `[…]`.)
)
+/
string formatLiteral(T)(auto ref const T value) @safe
{
    import std.conv : to;
    import std.format : format;
    import std.math : isInfinity, isNaN;

    alias U = Unqual!T;
    static if (is(U == typeof(null)))
        return "NULL";
    else static if (is(U : Nullable!V, V))
        return value.isNull ? "NULL" : formatLiteral(value.get);
    else static if (is(U == enum))
        return quoteString(value.to!string);
    else static if (is(U == bool))
        return value ? "true" : "false";
    else static if (isIntegral!U)
        return value.to!string;
    else static if (isFloatingPoint!U)
    {
        if (isNaN(value))
            return "nan";
        if (isInfinity(value))
            return value > 0 ? "inf" : "-inf";
        static if (is(U == float))
            return format("%.9g", value);
        else
            return format("%.17g", cast(double) value);
    }
    else static if (isSomeString!U)
        return quoteString(value.to!string);
    else static if (is(U : const(ubyte)[]))
        return quoteString(cast(const(char)[]) value);
    else static if (is(U == Date))
        return "toDate32('" ~ value.toISOExtString() ~ "')";
    else static if (is(U == SysTime))
    {
        import core.time : hnsecs;
        import std.datetime.date : DateTime;
        import std.datetime.timezone : UTC;

        const utc = value.toUTC();
        const dt = cast(DateTime) utc;
        return format("toDateTime64('%04d-%02d-%02d %02d:%02d:%02d.%07d', 7, 'UTC')", dt.year, dt.month, dt.day,
                dt.hour, dt.minute, dt.second, utc.fracSecs.total!"hnsecs");
    }
    else static if (is(U == UUID))
        return "toUUID('" ~ value.toString() ~ "')";
    else static if (isWideInt!U)
        return "to" ~ U.typeName ~ "('" ~ value.toString() ~ "')";
    else static if (is(U == BigInt))
        return "toInt256('" ~ value.toDecimalString() ~ "')";
    else static if (isArray!U)
    {
        string s = "[";
        foreach (i, ref e; value)
            s ~= (i ? ", " : "") ~ formatLiteral(e);
        return s ~ "]";
    }
    else
        static assert(0, "Cannot format values of type " ~ T.stringof ~ " as SQL literals");
}

///
@safe unittest
{
    assert(formatLiteral(42) == "42");
    assert(formatLiteral("it's") == `'it\'s'`);
    assert(formatLiteral([1, 2, 3]) == "[1, 2, 3]");
    assert(formatLiteral(null) == "NULL");
}

@safe unittest
{
    import std.datetime.date : DateTime;
    import std.datetime.timezone : UTC;
    import core.time : msecs;

    enum Side
    {
        buy,
        sell
    }

    assert(formatLiteral(-5L) == "-5" && formatLiteral(ulong.max) == "18446744073709551615");
    assert(formatLiteral(true) == "true");
    assert(formatLiteral(0.1) == "0.10000000000000001" && formatLiteral(1.5f) == "1.5");
    assert(formatLiteral(double.infinity) == "inf" && formatLiteral(-double.infinity) == "-inf");
    assert(formatLiteral(double.nan) == "nan");
    assert(formatLiteral("a\\b\n\t\0\x01'") == `'a\\b\n\t\0\x01\''`);
    const ubyte[] bytes = [0xFF, 'a'];
    assert(formatLiteral(bytes) == "'\xFFa'");
    assert(formatLiteral(Date(2025, 10, 29)) == "toDate32('2025-10-29')");
    assert(formatLiteral(Int128.min) == "toInt128('-170141183460469231731687303715884105728')");
    assert(formatLiteral(UInt256(5)) == "toUInt256('5')");
    assert(formatLiteral(BigInt("-12345678901234567890123")) == "toInt256('-12345678901234567890123')");
    assert(formatLiteral(SysTime(DateTime(2025, 10, 29, 12, 34, 56), UTC()) + 789.msecs)
            == "toDateTime64('2025-10-29 12:34:56.7890000', 7, 'UTC')");
    assert(formatLiteral(
            UUID("00112233-4455-6677-8899-aabbccddeeff"))
            == "toUUID('00112233-4455-6677-8899-aabbccddeeff')");
    assert(formatLiteral(Side.sell) == "'sell'");
    assert(formatLiteral(Nullable!int.init) == "NULL" && formatLiteral(Nullable!int(3)) == "3");
    assert(formatLiteral(["a", "b'"]) == `['a', 'b\'']`);
}

/// Quotes `s` as a SQL string literal.
private string quoteString(scope const(char)[] s) @safe pure
{
    import std.format : format;

    string r = "'";
    foreach (char c; s)
    {
        switch (c)
        {
        case '\'':
            r ~= `\'`;
            break;
        case '\\':
            r ~= `\\`;
            break;
        case '\n':
            r ~= `\n`;
            break;
        case '\r':
            r ~= `\r`;
            break;
        case '\t':
            r ~= `\t`;
            break;
        case '\0':
            r ~= `\0`;
            break;
        default:
            if (c < 0x20 || c == 0x7F)
                r ~= format(`\x%02X`, c);
            else
                r ~= c;
        }
    }
    return r ~ "'";
}
