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
import std.typecons : Rebindable, rebindable;
import std.variant : Variant;

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
        return cached.get;
    immutable(TimeZone) zone = loadTimeZone(name);
    timeZoneCache[name] = rebindable(zone);
    return zone;
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

private Rebindable!(immutable TimeZone)[string] timeZoneCache;

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
