/++
Time-of-day columns: `Time` (seconds) and `Time64(p)` (ticks of
10$(SUPERSCRIPT -p) seconds). Despite the name, a value is a signed time span:
the server allows -999:59:59 to 999:59:59, so the natural D type is
`core.time.Duration`; `std.datetime.date.TimeOfDay` works in struct mapping and
`readValue` for values from 00:00:00 to 23:59:59.

The types exist since ClickHouse 25.6, enabled by the `enable_time_time64_type`
setting until 25.12, which turned it on by default.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.time;

import core.time : Duration, dur;
import std.typecons : Nullable;
import std.variant : Variant;

import clickhoused.types.column;

/// The largest magnitude of a `Time` value in seconds: 999:59:59.
enum long maxTimeSeconds = 999 * 3600 + 59 * 60 + 59;

/// `Time` column: whole seconds, stored as `int`.
final class TimeColumn : FixedColumn!int
{
    /// Creates an empty column.
    this(string name, string typeName) @safe pure nothrow
    {
        super(name, typeName);
    }

    /// The value in `row`.
    Duration opIndex(size_t row) const @safe pure nothrow
    {
        return dur!"seconds"(data[row]);
    }

    override Duration getDuration(size_t row) const @safe
    {
        return this[row];
    }

    /// Seconds.
    override long getLong(size_t row) const @safe
    {
        return data[row];
    }

    /// Seconds.
    override double getDouble(size_t row) const @safe
    {
        return data[row];
    }

    /// The value as `[-]hh:mm:ss`, with three hour digits from 100 hours on. Quoted inside arrays.
    override string getString(size_t row) const @safe
    {
        return formatTime(data[row], 0);
    }

    override protected @property bool quotedInText() const @safe pure nothrow
    {
        return true;
    }

    /// A `Duration`.
    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(this[row]);
    }

    override void appendDefault() @safe
    {
        push(0);
    }

    /// Appends seconds.
    override void appendLong(long value) @safe
    {
        if (value < -maxTimeSeconds || value > maxTimeSeconds)
            throw appendError("long", value);
        push(cast(int) value);
    }

    /// ditto
    override void appendUlong(ulong value) @safe
    {
        if (value > maxTimeSeconds)
            throw appendError("ulong", value);
        push(cast(int) value);
    }

    /// Appends seconds, truncated towards zero as the server converts them.
    override void appendDouble(double value) @safe
    {
        if (!(value > -(maxTimeSeconds + 1) && value < maxTimeSeconds + 1))
            throw appendError("double", value);
        push(cast(int) value);
    }

    /// Appends the whole seconds of `value` (truncated towards zero).
    override void appendDuration(Duration value) @safe
    {
        appendLong(value.total!"seconds");
    }

    /++
    Parses `[-]h:mm:ss` with one to three hour digits, `[-]m:ss` or `[-]s`
    (minutes and seconds with up to two digits), as the server does.
    +/
    override void appendString(string value) @safe
    {
        const ticks = parseTime(value, 0, false);
        if (ticks.isNull)
            throw appendError("string", value);
        push(cast(int) ticks.get);
    }
}

///
@system unittest
{
    import core.time : hours, minutes, seconds;

    auto c = new TimeColumn("t", "Time");
    c.appendString("25:01:01");
    c.appendDuration(-(1.hours + 1.minutes + 1.seconds));
    c.appendLong(5);
    assert(c.data == [90_061, -3661, 5]);
    assert(c.getString(0) == "25:01:01" && c.getString(1) == "-01:01:01" && c.getString(2) == "00:00:05");
    assert(c[1] == -3661.seconds && c.getVariant(2).get!Duration == 5.seconds);
    assert(c.getQuotedString(2) == "'00:00:05'");
}

/++
`Time64(p)` column: ticks of 10$(SUPERSCRIPT -p) seconds, stored as `long`.

`Duration` has a resolution of 100 ns, so with precision 8 or 9 the sub-100 ns
digits are dropped by `getDuration`; `getString` and `data` keep them.
+/
final class Time64Column : FixedColumn!long
{
    /// Number of decimal digits of the fractional seconds (0 to 9).
    immutable uint precision;

    /++
    Creates an empty column.

    Params:
        name = column name.
        precision = digits of fractional seconds, 0 to 9.
        typeName = ClickHouse type name.
    +/
    this(string name, uint precision, string typeName) @safe pure nothrow
    {
        assert(precision <= 9);
        super(name, typeName);
        this.precision = precision;
    }

    /// The value in `row` (truncated towards zero to 100 ns).
    Duration opIndex(size_t row) const @safe pure nothrow
    {
        const ticks = data[row];
        if (precision <= 7)
            return dur!"hnsecs"(ticks * tenTo(7 - precision));
        return dur!"hnsecs"(ticks / tenTo(precision - 7));
    }

    override Duration getDuration(size_t row) const @safe
    {
        return this[row];
    }

    /// Raw ticks.
    override long getLong(size_t row) const @safe
    {
        return data[row];
    }

    /// Seconds.
    override double getDouble(size_t row) const @safe
    {
        return cast(double) data[row] / tenTo(precision);
    }

    /// The value as `[-]hh:mm:ss.fff…` (`precision` digits). Quoted inside arrays.
    override string getString(size_t row) const @safe
    {
        return formatTime(data[row], precision);
    }

    override protected @property bool quotedInText() const @safe pure nothrow
    {
        return true;
    }

    /// A `Duration`.
    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(this[row]);
    }

    override void appendDefault() @safe
    {
        push(0);
    }

    /// The largest magnitude of a value in ticks: 999:59:59.99…
    private @property long maxTicks() const @safe pure nothrow
    {
        return (maxTimeSeconds + 1) * tenTo(precision) - 1;
    }

    /// Appends raw ticks.
    override void appendLong(long value) @safe
    {
        if (value < -maxTicks || value > maxTicks)
            throw appendError("long", value);
        push(value);
    }

    /// ditto
    override void appendUlong(ulong value) @safe
    {
        if (value > maxTicks)
            throw appendError("ulong", value);
        push(cast(long) value);
    }

    /// Appends seconds, truncated towards zero to the column precision as the server converts them.
    override void appendDouble(double value) @safe
    {
        if (!(value > -(maxTimeSeconds + 1) && value < maxTimeSeconds + 1))
            throw appendError("double", value);
        push(cast(long)(value * tenTo(precision)));
    }

    /// Appends `value`, truncated towards zero to the column precision.
    override void appendDuration(Duration value) @safe
    {
        const hnsecs = value.total!"hnsecs";
        if (precision <= 7)
        {
            appendLong(hnsecs / tenTo(7 - precision));
            return;
        }
        const factor = tenTo(precision - 7);
        if (hnsecs > maxTicks / factor || hnsecs < -maxTicks / factor)
            throw appendError("Duration", value);
        push(hnsecs * factor);
    }

    /// Parses the forms `TimeColumn.appendString` accepts, plus a fraction
    /// `.fff…`; digits beyond the precision are dropped.
    override void appendString(string value) @safe
    {
        const ticks = parseTime(value, precision, true);
        if (ticks.isNull)
            throw appendError("string", value);
        push(ticks.get);
    }
}

///
@system unittest
{
    import core.time : msecs;

    auto c = new Time64Column("t", 3, "Time64(3)");
    c.appendString("12:34:56.78999"); // extra digits are dropped
    c.appendDuration(-250.msecs);
    c.appendDouble(1.5);
    assert(c.data == [45_296_789, -250, 1500]);
    assert(c.getString(0) == "12:34:56.789" && c.getString(1) == "-00:00:00.250");
    assert(c[2] == 1500.msecs && c.getDouble(2) == 1.5 && c.getVariant(1).get!Duration == -250.msecs);
}

/// `10^n` for `n` from 0 to 18.
private long tenTo(uint n) @safe pure nothrow @nogc
{
    long p = 1;
    foreach (_; 0 .. n)
        p *= 10;
    return p;
}

/++
Formats `ticks` (of 10$(SUPERSCRIPT -precision) seconds) as the server does:
`[-]hh:mm:ss`, three hour digits from 100 hours on, then a point and exactly
`precision` fraction digits. The sign is kept when only the fraction is
non-zero (`-00:00:00.25`).
+/
private string formatTime(long ticks, uint precision) @safe pure
{
    import std.format : format;

    const negative = ticks < 0;
    const magnitude = negative ? -ticks : ticks;
    const scale = tenTo(precision);
    const whole = magnitude / scale;
    auto text = format("%s%02d:%02d:%02d", negative ? "-" : "", whole / 3600, whole / 60 % 60, whole % 60);
    if (precision > 0)
        text ~= format(".%0*d", precision, magnitude % scale);
    return text;
}

/++
Parses a time as the server does: `[-]h:mm:ss` (one to three hour digits),
`[-]m:ss` or `[-]s` (up to two digits each), then, if `fraction` is set, an
optional `.` and digits, of which the first `precision` are kept. Minutes and
seconds are not checked against 60, as on the server, but the total must stay
within ±999:59:59.

Returns: the value in ticks of 10$(SUPERSCRIPT -precision) seconds, or null
if `text` is not valid.
+/
private Nullable!long parseTime(string text, uint precision, bool fraction) @safe pure nothrow
{
    import std.ascii : isDigit;

    size_t i;
    const negative = text.length > 0 && text[0] == '-';
    if (negative)
        i++;
    // Groups of digits separated by ':'
    long[3] groups;
    size_t[3] widths;
    size_t count;
    for (;;)
    {
        if (count == 3)
            return Nullable!long.init;
        const start = i;
        while (i < text.length && isDigit(text[i]))
            groups[count] = groups[count] * 10 + (text[i++] - '0');
        widths[count] = i - start;
        count++;
        if (i < text.length && text[i] == ':')
        {
            i++;
            continue;
        }
        break;
    }
    // h:mm:ss with 1-3 hour digits, m:ss or s with 1-2 leading digits; the others take exactly 2
    if (widths[0] < 1 || widths[0] > (count == 3 ? 3 : 2))
        return Nullable!long.init;
    foreach (w; widths[1 .. count])
        if (w != 2)
            return Nullable!long.init;
    long seconds; // h * 3600 + m * 60 + s, m * 60 + s, or s
    foreach (g; groups[0 .. count])
        seconds = seconds * 60 + g;
    if (seconds > maxTimeSeconds)
        return Nullable!long.init;

    const scale = tenTo(precision);
    long fractionTicks;
    if (fraction && i < text.length && text[i] == '.')
    {
        i++;
        const start = i;
        long unit = scale;
        while (i < text.length && isDigit(text[i]))
        {
            unit /= 10;
            fractionTicks += (text[i++] - '0') * unit;
        }
        if (i == start)
            return Nullable!long.init;
    }
    if (i != text.length)
        return Nullable!long.init;
    const ticks = seconds * scale + fractionTicks;
    return Nullable!long(negative ? -ticks : ticks);
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.exception : ClientException;

    // Text checked against the server (toString, CAST from String)
    auto t = new TimeColumn("t", "Time");
    foreach (s; ["0", "05", "7:05", "17:05", "1:02:03", "999:59:59", "-00:00:01", "1:99:99"])
        t.appendString(s);
    assert(t.data == [0, 5, 425, 1025, 3723, 3_599_999, -1, 9639]);
    assert(t.getString(5) == "999:59:59" && t.getString(6) == "-00:00:01" && t.getString(7) == "02:40:39");
    assert(t.getString(3) == "00:17:05" && t.getLong(4) == 3723 && t.getDouble(6) == -1);
    foreach (bad; [
        "", "-", "1000:00:00", "1:2:3", "100", "1:2", "12:34:56.5", "1:00:00:00", "a", "01:02:03 "
    ])
        assertThrown!ClientException(t.appendString(bad), bad);
    assertThrown!ClientException(t.appendLong(maxTimeSeconds + 1));
    assertThrown!ClientException(t.appendDouble(-3_600_000));
    assertThrown!ClientException(t.appendDouble(double.nan));
    t.appendDouble(-1.7); // truncated towards zero, as toTime(-1.7)
    t.appendUlong(maxTimeSeconds);
    assert(t.data[$ - 2 .. $] == [-1, 3_599_999] && t.length == 10);

    auto t1 = new Time64Column("t", 1, "Time64(1)");
    t1.appendString("-1:00:00.5");
    t1.appendString("-00:00:00.5");
    t1.appendString("5");
    assert(t1.getString(0) == "-01:00:00.5" && t1.getString(1) == "-00:00:00.5" && t1.getString(2) == "00:00:05.0");
    assertThrown!ClientException(t1.appendString("1."));

    auto t9 = new Time64Column("t", 9, "Time64(9)");
    t9.appendDouble(1.5);
    t9.appendString("999:59:59.999999999");
    assert(t9.getString(0) == "00:00:01.500000000" && t9.getString(1) == "999:59:59.999999999");
    assertThrown!ClientException(t9.appendLong(t9.data[1] + 1));
    t9.appendDuration(dur!"hnsecs"(-3));
    assert(t9.data[2] == -300 && t9[2] == dur!"hnsecs"(-3));
    t9.data ~= 1_234_567_899; // sub-100 ns digits: kept by getString, dropped by getDuration
    assert(t9.getString(3) == "00:00:01.234567899" && t9[3] == dur!"hnsecs"(12_345_678));

    auto t0 = new Time64Column("t", 0, "Time64(0)");
    t0.appendString("01:02:03.98765");
    assert(t0.getString(0) == "01:02:03");
}

// Golden bytes from `SELECT toTime(-3661), toTime64('-0:00:00.25', 2), toTime64('999:59:59.999999', 6) FORMAT Native`
@safe unittest
{
    import clickhoused.io.buffer : BufferedReader, BufferedWriter;
    import clickhoused.io.mock : MockTransport;

    void roundTrip(Column c, const(ubyte)[] bytes, string text)
    {
        auto t = new MockTransport;
        t.feed(bytes);
        c.readData(new BufferedReader(t), 1);
        assert(c.getString(0) == text, c.getString(0));
        auto w = new MockTransport;
        auto writer = new BufferedWriter(w);
        c.writeData(writer);
        writer.flush();
        assert(w.written == bytes);
    }

    roundTrip(new TimeColumn("t", "Time"), [0xb3, 0xf1, 0xff, 0xff], "-01:01:01");
    roundTrip(new Time64Column("u", 2, "Time64(2)"), [
        0xe7, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
    ],
    "-00:00:00.25");
    roundTrip(new Time64Column("v", 6, "Time64(6)"), [
        0xff, 0x9f, 0xb8, 0x30, 0x46, 0x03, 0x00, 0x00
    ],
    "999:59:59.999999");
}
