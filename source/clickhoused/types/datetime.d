/++
Date and time columns: `Date`, `Date32`, `DateTime[(tz)]` and
`DateTime64(precision[, tz])`.

Values are stored raw, exactly as on the wire (days or seconds or ticks since
1970-01-01 00:00:00 UTC), and converted on access. A ClickHouse timestamp is
an absolute point in time; the column timezone only affects how it is shown,
so `getSysTime` returns a `SysTime` set to that timezone.

Timezones are looked up in the system time zone database (`PosixTimeZone`).
When a name cannot be resolved, e.g. on Windows, which has no such database,
UTC is used instead. The point in time is still correct; only the timezone of
the returned `SysTime` and the text from `getString` differ.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.datetime;

import core.time : dur;
import std.datetime.date : Date, DateTime;
import std.datetime.systime : SysTime, unixTimeToStdTime;
import std.datetime.timezone : TimeZone, UTC;
import std.variant : Variant;

import clickhoused.exception : ClientException;
import clickhoused.types.column;

/// Day number of 1970-01-01 in `std.datetime`'s Gregorian day count.
private enum int epochDayNumber = 719_163;

/// `Date` column: days since 1970-01-01, stored as `ushort` (range 1970-01-01 to 2149-06-06).
final class DateColumn : FixedColumn!ushort
{
    /// Creates an empty column.
    this(string name, string typeName = "Date") @safe pure nothrow
    {
        super(name, typeName);
    }

    /// The date in `row`.
    Date opIndex(size_t row) const @safe pure nothrow
    {
        return dateFromDays(data[row]);
    }

    override Date getDate(size_t row) const @safe
    {
        return this[row];
    }

    /// Midnight UTC of the date.
    override SysTime getSysTime(size_t row) const @safe
    {
        return SysTime(DateTime(this[row]), UTC());
    }

    /// Days since 1970-01-01.
    override long getLong(size_t row) const @safe
    {
        return data[row];
    }

    /// The date as `YYYY-MM-DD`.
    override string getString(size_t row) const @safe
    {
        return this[row].toISOExtString();
    }

    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(this[row]);
    }

    private enum long minDays = 0;
    private enum long maxDays = ushort.max;

    override void appendDefault() @safe
    {
        data ~= 0;
    }

    /// Accepts dates from 1970-01-01 to 2149-06-06.
    override void appendDate(Date value) @safe
    {
        const days = value.dayOfGregorianCal - epochDayNumber;
        if (days < minDays || days > maxDays)
            throw appendError("Date", value);
        data ~= cast(typeof(data[0])) days;
    }

    /// Appends the date of `value` in its own timezone.
    override void appendSysTime(SysTime value) @safe
    {
        appendDate(cast(Date) value);
    }

    /// Appends days since 1970-01-01.
    override void appendLong(long value) @safe
    {
        if (value < minDays || value > maxDays)
            throw appendError("long", value);
        data ~= cast(typeof(data[0])) value;
    }

    /// Parses `YYYY-MM-DD`.
    override void appendString(string value) @safe
    {
        appendDate(parseDate(value, this));
    }
}

/// `Date32` column: days since 1970-01-01, stored as `int` (range 1900-01-01 to 2299-12-31).
final class Date32Column : FixedColumn!int
{
    /// Creates an empty column.
    this(string name, string typeName = "Date32") @safe pure nothrow
    {
        super(name, typeName);
    }

    /// The date in `row`.
    Date opIndex(size_t row) const @safe pure nothrow
    {
        return dateFromDays(data[row]);
    }

    override Date getDate(size_t row) const @safe
    {
        return this[row];
    }

    /// Midnight UTC of the date.
    override SysTime getSysTime(size_t row) const @safe
    {
        return SysTime(DateTime(this[row]), UTC());
    }

    /// Days since 1970-01-01 (negative before 1970).
    override long getLong(size_t row) const @safe
    {
        return data[row];
    }

    /// The date as `YYYY-MM-DD`.
    override string getString(size_t row) const @safe
    {
        return this[row].toISOExtString();
    }

    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(this[row]);
    }

    private enum long minDays = -25_567; // 1900-01-01
    private enum long maxDays = 120_529; // 2299-12-31

    override void appendDefault() @safe
    {
        data ~= 0;
    }

    /// Accepts dates from 1900-01-01 to 2299-12-31.
    override void appendDate(Date value) @safe
    {
        const days = value.dayOfGregorianCal - epochDayNumber;
        if (days < minDays || days > maxDays)
            throw appendError("Date", value);
        data ~= cast(typeof(data[0])) days;
    }

    /// Appends the date of `value` in its own timezone.
    override void appendSysTime(SysTime value) @safe
    {
        appendDate(cast(Date) value);
    }

    /// Appends days since 1970-01-01.
    override void appendLong(long value) @safe
    {
        if (value < minDays || value > maxDays)
            throw appendError("long", value);
        data ~= cast(typeof(data[0])) value;
    }

    /// Parses `YYYY-MM-DD`.
    override void appendString(string value) @safe
    {
        appendDate(parseDate(value, this));
    }
}

/// `DateTime` column: seconds since the Unix epoch, stored as `uint`.
final class DateTimeColumn : FixedColumn!uint
{
    /// Timezone used to present values: the type's timezone parameter, or the
    /// server timezone if the type has none.
    string timezone;

    /++
    Creates an empty column.

    Params:
        name = column name.
        typeName = ClickHouse type name.
        timezone = timezone for presenting values; empty means UTC.
    +/
    this(string name, string typeName = "DateTime", string timezone = null) @safe pure nothrow
    {
        super(name, typeName);
        this.timezone = timezone;
    }

    /// The point in time in `row`, in the column timezone.
    SysTime opIndex(size_t row) const @safe
    {
        return SysTime(unixTimeToStdTime(data[row]), resolveTimeZone(timezone));
    }

    override SysTime getSysTime(size_t row) const @safe
    {
        return this[row];
    }

    /// The date in the column timezone.
    override Date getDate(size_t row) const @safe
    {
        return cast(Date) this[row];
    }

    /// Seconds since the Unix epoch.
    override long getLong(size_t row) const @safe
    {
        return data[row];
    }

    /// The value as `YYYY-MM-DD hh:mm:ss` in the column timezone.
    override string getString(size_t row) const @safe
    {
        return formatDateTime(this[row], 0);
    }

    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(this[row]);
    }

    override void appendDefault() @safe
    {
        data ~= 0;
    }

    /// Appends the point in time, truncated to whole seconds. Accepts
    /// 1970-01-01 00:00:00 UTC to 2106-02-07 06:28:15 UTC.
    override void appendSysTime(SysTime value) @safe
    {
        appendLong(floorDiv(value.stdTime - unixTimeToStdTime(0), 10_000_000));
    }

    /// Appends midnight of `value` in the column timezone.
    override void appendDate(Date value) @safe
    {
        appendSysTime(SysTime(DateTime(value), resolveTimeZone(timezone)));
    }

    /// Appends seconds since the Unix epoch.
    override void appendLong(long value) @safe
    {
        if (value < 0 || value > uint.max)
            throw appendError("long", value);
        data ~= cast(uint) value;
    }

    /// Parses `YYYY-MM-DD hh:mm:ss` in the column timezone.
    override void appendString(string value) @safe
    {
        appendSysTime(parseDateTime(value, timezone, 0, this).time);
    }
}

/++
`DateTime64(precision[, tz])` column: ticks of 10$(SUPERSCRIPT -precision) seconds
since the Unix epoch, stored as `long`.

`SysTime` has a resolution of 100 ns, so with precision 8 or 9 the sub-100 ns
digits are dropped by `getSysTime`; `getString` and `data` keep them.
+/
final class DateTime64Column : FixedColumn!long
{
    /// Number of decimal digits of the fractional seconds (0 to 9).
    immutable uint precision;
    /// Timezone used to present values: the type's timezone parameter, or the
    /// server timezone if the type has none.
    string timezone;

    /++
    Creates an empty column.

    Params:
        name = column name.
        precision = digits of fractional seconds, 0 to 9.
        typeName = ClickHouse type name.
        timezone = timezone for presenting values; empty means UTC.
    +/
    this(string name, uint precision, string typeName, string timezone = null) @safe pure nothrow
    {
        assert(precision <= 9);
        super(name, typeName);
        this.precision = precision;
        this.timezone = timezone;
    }

    /// The point in time in `row`, in the column timezone.
    SysTime opIndex(size_t row) const @safe
    {
        return SysTime(unixTimeToStdTime(0) + ticksToHnsecs(data[row], precision), resolveTimeZone(timezone));
    }

    override SysTime getSysTime(size_t row) const @safe
    {
        return this[row];
    }

    /// The date in the column timezone.
    override Date getDate(size_t row) const @safe
    {
        return cast(Date) this[row];
    }

    /// Raw ticks since the Unix epoch.
    override long getLong(size_t row) const @safe
    {
        return data[row];
    }

    /// The value as `YYYY-MM-DD hh:mm:ss.fff…` (`precision` digits) in the column timezone.
    override string getString(size_t row) const @safe
    {
        const ticks = data[row];
        const scale = pow10(precision);
        long seconds = ticks / scale;
        long fraction = ticks % scale;
        if (fraction < 0)
        {
            seconds--;
            fraction += scale;
        }
        auto time = SysTime(unixTimeToStdTime(seconds), resolveTimeZone(timezone));
        return formatDateTime(time, precision, fraction);
    }

    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(this[row]);
    }

    override void appendDefault() @safe
    {
        data ~= 0;
    }

    /// Appends the point in time, truncated to the column precision.
    override void appendSysTime(SysTime value) @safe
    {
        const hnsecs = value.stdTime - unixTimeToStdTime(0);
        if (precision <= 7)
        {
            data ~= floorDiv(hnsecs, pow10(7 - precision));
            return;
        }
        const factor = pow10(precision - 7);
        if (hnsecs > long.max / factor || hnsecs < long.min / factor)
            throw appendError("SysTime", value);
        data ~= hnsecs * factor;
    }

    /// Appends midnight of `value` in the column timezone.
    override void appendDate(Date value) @safe
    {
        appendSysTime(SysTime(DateTime(value), resolveTimeZone(timezone)));
    }

    /// Appends raw ticks since the Unix epoch.
    override void appendLong(long value) @safe
    {
        data ~= value;
    }

    /// Parses `YYYY-MM-DD hh:mm:ss[.fraction]` in the column timezone;
    /// fraction digits beyond the precision are dropped.
    override void appendString(string value) @safe
    {
        const parsed = parseDateTime(value, timezone, precision, this);
        const seconds = parsed.time.toUnixTime!long;
        const scale = pow10(precision);
        // seconds * scale + fraction, where 0 <= fraction < scale
        if (seconds > (long.max - parsed.fraction) / scale || seconds < long.min / scale)
            throw appendError("string", value);
        data ~= seconds * scale + parsed.fraction;
    }
}

/++
Returns the timezone named `name` (e.g. `"Europe/Lisbon"`), or UTC if `name` is
empty or cannot be resolved. Results are cached per thread.
+/
immutable(TimeZone) resolveTimeZone(string name) @safe
{
    if (name.length == 0 || name == "UTC")
        return UTC();
    if (auto cached = name in timeZoneCache)
        return cached.zone;
    auto entry = new CachedZone(loadTimeZone(name));
    timeZoneCache[name] = entry;
    return entry.zone;
}

///
@safe unittest
{
    auto c = new DateTimeColumn("t", "DateTime('UTC')", "UTC");
    c.data = [1_761_741_296]; // 2025-10-29 12:34:56 UTC
    assert(c.getString(0) == "2025-10-29 12:34:56");
    assert(c.getSysTime(0).toUnixTime == 1_761_741_296);
    assert(c.getDate(0) == Date(2025, 10, 29));
}

@safe unittest
{
    // Date and Date32, including dates before 1970
    auto d = new DateColumn("d");
    d.data = [0, 20_390];
    assert(d[0] == Date(1970, 1, 1) && d.getString(1) == "2025-10-29");

    auto d32 = new Date32Column("d");
    d32.data = [-25_567, 120_529];
    assert(d32[0] == Date(1900, 1, 1) && d32[1] == Date(2299, 12, 31));
}

@safe unittest
{
    // DateTime64: precision, negative ticks, sub-100ns digits
    auto c = new DateTime64Column("t", 3, "DateTime64(3, 'UTC')", "UTC");
    c.data = [1_761_741_296_789, -1];
    assert(c.getString(0) == "2025-10-29 12:34:56.789");
    assert(c[0].fracSecs == dur!"msecs"(789));
    assert(c.getString(1) == "1969-12-31 23:59:59.999");

    auto n = new DateTime64Column("t", 9, "DateTime64(9)", "UTC");
    n.data = [123_456_789];
    assert(n.getString(0) == "1970-01-01 00:00:00.123456789");
    assert(n[0].fracSecs == dur!"hnsecs"(1_234_567));
}

@safe unittest
{
    // Timezones: same instant, different presentation; unknown names fall back to UTC
    version (Posix)
    {
        auto c = new DateTimeColumn("t", "DateTime('Asia/Tokyo')", "Asia/Tokyo");
        c.data = [0];
        assert(c.getString(0) == "1970-01-01 09:00:00");
        assert(c[0].toUnixTime == 0);
    }
    assert(resolveTimeZone("No/Such_Zone") is UTC());
}

private final class CachedZone
{
    immutable TimeZone zone;

    this(immutable TimeZone zone) @safe pure nothrow
    {
        this.zone = zone;
    }
}

private CachedZone[string] timeZoneCache;

private long floorDiv(long a, long b) @safe pure nothrow @nogc
{
    long q = a / b;
    if (a % b < 0)
        q--;
    return q;
}

/// Parses `YYYY-MM-DD`.
private Date parseDate(string value, const Column column) @safe
{
    import std.datetime.date : DateTimeException;

    try
        return Date.fromISOExtString(value);
    catch (DateTimeException)
        throw new ClientException("Cannot parse '" ~ value ~ "' as a date for column '" ~ column.name ~ "'");
}

/// Result of `parseDateTime`.
private struct ParsedDateTime
{
    /// Whole seconds, as a point in time.
    SysTime time;
    /// Fractional seconds, scaled to the requested number of digits.
    long fraction;
}

/// Parses `YYYY-MM-DD hh:mm:ss[.fraction]` as local time in `timezone`, with
/// the fraction scaled to `precision` digits.
private ParsedDateTime parseDateTime(string value, string timezone, uint precision, const Column column) @safe
{
    ParsedDateTime result;
    long fraction;
    import std.algorithm.searching : findSplit;
    import std.array : replace;
    import std.ascii : isDigit;
    import std.datetime.date : DateTimeException;

    ClientException failure()
    {
        return new ClientException("Cannot parse '" ~ value ~ "' as a date and time for column '" ~ column.name ~ "'");
    }

    auto parts = value.findSplit(".");
    if (parts[1].length)
    {
        foreach (i, char c; parts[2])
        {
            if (!isDigit(c))
                throw failure();
            if (i < precision)
                fraction = fraction * 10 + (c - '0');
        }
        foreach (i; parts[2].length .. precision)
            fraction *= 10;
    }
    try
        result.time = SysTime(DateTime.fromISOExtString(parts[0].replace(" ", "T")), resolveTimeZone(timezone));
    catch (DateTimeException)
        throw failure();
    result.fraction = fraction;
    return result;
}

@safe unittest
{
    import std.exception : assertThrown;

    // Appending dates and times, round-tripping through the getters
    auto d = new DateColumn("d");
    d.appendDate(Date(2025, 10, 29));
    d.appendString("1970-01-01");
    d.appendSysTime(SysTime(DateTime(2025, 10, 29, 23, 0, 0), UTC()));
    assert(d.getString(0) == "2025-10-29" && d.data[1] == 0 && d.getString(2) == "2025-10-29");
    assertThrown!ClientException(d.appendDate(Date(1969, 12, 31)));
    assertThrown!ClientException(d.appendString("29.10.2025"));

    auto d32 = new Date32Column("d");
    d32.appendDate(Date(1900, 1, 1));
    assertThrown!ClientException(d32.appendDate(Date(2300, 1, 1)));

    auto t = new DateTimeColumn("t", "DateTime('UTC')", "UTC");
    t.appendString("2025-10-29 12:34:56");
    t.appendSysTime(SysTime(DateTime(2025, 10, 29, 12, 34, 56), UTC()) + dur!"msecs"(999));
    t.appendDate(Date(1970, 1, 2));
    assert(t.data == [1_761_741_296, 1_761_741_296, 86_400]);
    assertThrown!ClientException(t.appendLong(-1));

    auto t64 = new DateTime64Column("t", 3, "DateTime64(3, 'UTC')", "UTC");
    t64.appendString("2025-10-29 12:34:56.7891");
    t64.appendString("1969-12-31 23:59:59.5");
    t64.appendSysTime(SysTime(DateTime(1970, 1, 1), UTC()) - dur!"hnsecs"(1));
    assert(t64.data == [1_761_741_296_789, -500, -1]);
    assert(t64.getString(0) == "2025-10-29 12:34:56.789");

    auto t9 = new DateTime64Column("t", 9, "DateTime64(9)", "UTC");
    t9.appendSysTime(SysTime(DateTime(1970, 1, 1), UTC()) + dur!"hnsecs"(3));
    assert(t9.data == [300]);
    assertThrown!ClientException(t9.appendSysTime(SysTime(DateTime(2299, 1, 1), UTC())));

    version (Posix)
    {
        auto tokyo = new DateTimeColumn("t", "DateTime('Asia/Tokyo')", "Asia/Tokyo");
        tokyo.appendString("1970-01-01 09:00:00");
        assert(tokyo.data == [0]);
    }
}

private immutable(TimeZone) loadTimeZone(string name) @safe
{
    version (Posix)
    {
        import std.datetime.timezone : PosixTimeZone;

        try
            return PosixTimeZone.getTimeZone(name);
        catch (Exception)
            return UTC();
    }
    else
        return UTC();
}

private Date dateFromDays(long days) @safe pure nothrow
{
    Date d;
    d.dayOfGregorianCal = cast(int)(epochDayNumber + days);
    return d;
}

private long pow10(uint n) @safe pure nothrow @nogc
{
    long r = 1;
    foreach (i; 0 .. n)
        r *= 10;
    return r;
}

/// Converts ticks of 10^-precision seconds to hnsecs (100 ns units), rounding down.
private long ticksToHnsecs(long ticks, uint precision) @safe pure nothrow @nogc
{
    if (precision <= 7)
        return ticks * pow10(7 - precision);
    const divisor = pow10(precision - 7);
    long q = ticks / divisor;
    if (ticks % divisor < 0)
        q--; // round toward negative infinity
    return q;
}

/// Formats as `YYYY-MM-DD hh:mm:ss[.fraction]` in the timezone of `time`.
private string formatDateTime(SysTime time, uint precision, long fraction = 0) @safe
{
    import std.format : format;

    const dt = cast(DateTime) time;
    auto s = format("%04d-%02d-%02d %02d:%02d:%02d", dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second);
    if (precision)
        s ~= format(".%0*d", precision, fraction);
    return s;
}
