/++
`JSON` columns (the new JSON type, ClickHouse 24.8+), as JSON text.

By default the server sends JSON columns in its internal form (typed paths,
dynamic paths and binary-encoded shared data), which this client doesn't
decode. Since 24.10 the setting `output_format_native_write_json_as_string`
makes it send one JSON text per row instead, and `Connection` asks for it
(see `ConnectionOptions.simpleNativeFormats`). The server also accepts JSON
text on insert. On a server without that setting, or with it turned off,
reading a JSON column throws `ClientException`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.json;

import std.json : JSONValue;
import std.variant : Variant;

import clickhoused.exception : ClientException, ProtocolException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter, readString, writeString;
import clickhoused.types.column : appendFast, Column, growRows, makeVariant;

/++
The `maxDepth` that JSON text is parsed with: `std.json` then accepts 1001
nested objects and arrays, as ClickHouse 26.11 does (checked). Deeper text is
rejected instead of parsed, which would overflow the stack.
+/
enum int maxJsonDepth = 1000;

/++
Parses JSON text into `parsed` with the `maxJsonDepth` limit. Returns false, with the reason
in `error`, if the text is not valid JSON, is nested too deeply, or has a
number that doesn't fit (std.json then throws `ConvException`, not `JSONException`).
+/
package(clickhoused) bool tryParseJson(string text, out JSONValue parsed, out string error) @safe
{
    import std.conv : ConvException;
    import std.json : JSONException, parseJSON;

    try
    {
        parsed = parseJSON(text, maxJsonDepth);
        return true;
    }
    catch (JSONException e)
        error = e.msg;
    catch (ConvException e)
        error = e.msg;
    return false;
}

/++
`JSON` column: one JSON text per row, as the server writes it (`toString(j)`:
keys sorted, paths with null or empty-object values left out).

Appended text must be a JSON object; it is checked with `std.json` first,
because the server closes the connection when it can't parse the JSON of an
insert. `std.json.JSONValue` maps to it in struct mapping, `readValue` and
inserts.
+/
final class JsonColumn : Column
{
    /// The serialization version of the JSON-as-text form.
    enum ulong stringVersion = 1;

    /// JSON text of each row.
    string[] data;
    private string[] spare; // room for appends; see `appendFast`

    /// Creates an empty column.
    this(string name, string typeName = "JSON") @safe pure nothrow
    {
        super(name, typeName);
    }

    override @property size_t length() const @safe pure nothrow
    {
        return data.length;
    }

    /++
    Reads the serialization version, which must be the text form.

    Throws: `ClientException` for the server's internal forms, which this
    client can't decode (the connection then closes, as the rest of the block
    can't be skipped).
    +/
    override void readStatePrefix(BufferedReader reader) @safe
    {
        import std.conv : to;

        const serializationVersion = reader.readFixed!ulong();
        if (serializationVersion == stringVersion)
            return;
        if (serializationVersion > 4)
            throw new ProtocolException("Column '" ~ name ~ "' (" ~ typeName ~ "): unknown JSON serialization version "
                    ~ serializationVersion.to!string);
        throw new ClientException("Column '" ~ name ~ "' (" ~ typeName ~ "): the server sent JSON in its internal "
                ~ "form, which this client doesn't decode. It needs output_format_native_write_json_as_string=1 "
                ~ "(ClickHouse 24.10 and newer; sent automatically unless ConnectionOptions.simpleNativeFormats "
                ~ "is off)");
    }

    /// Writes the version of the text form.
    override void writeStatePrefix(BufferedWriter writer) const @safe
    {
        writer.writeFixed!ulong(stringVersion);
    }

    override void readData(BufferedReader reader, size_t rows) @safe
    {
        import clickhoused.io.buffer : StringArena;

        data = null;
        StringArena arena;
        while (data.length < rows)
        {
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

    /// Quoted inside arrays and tuples, like a string.
    override protected @property bool quotedInText() const @safe pure nothrow
    {
        return true;
    }

    /// The JSON text.
    override string getString(size_t row) const @safe
    {
        return data[row];
    }

    override const(ubyte)[] getBytes(size_t row) const @safe
    {
        return cast(const(ubyte)[]) data[row];
    }

    /// The JSON text, as a `string`.
    override Variant getVariant(size_t row) const @safe
    {
        return makeVariant(data[row]);
    }

    /// Appends `{}`, the server's default for JSON.
    override void appendDefault() @safe
    {
        appendFast(data, spare, "{}");
    }

    override void truncate(size_t length) @safe
    {
        if (length < data.length)
            data.length = length;
    }

    override void appendFrom(const Column source, size_t row) @safe
    {
        appendFast(data, spare, sameKind!JsonColumn(source).data[row]);
    }

    /++
    Appends JSON text, e.g. `{"a": 1}`, sent as it is.

    Throws: `ClientException` if `value` is not a JSON object.
    +/
    override void appendString(string value) @safe
    {
        import std.json : JSONType;

        JSONValue parsed;
        string error;
        if (!tryParseJson(value, parsed, error) || parsed.type != JSONType.object)
            throw appendError("string", value);
        appendFast(data, spare, value);
    }

    /// ditto
    override void appendBytes(const(ubyte)[] value) @safe
    {
        appendString(cast(string) value.idup); // text bytes, checked as JSON
    }
}

// Golden bytes from `SELECT j FROM t FORMAT Native` with output_format_native_write_json_as_string=1
@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.io.mock : MockTransport;
    import clickhoused.types.factory : createColumn;

    const json = `{"a":{"b":5},"q":[1,2]}`;
    const bytes = cast(const(ubyte)[])[1, 0, 0, 0, 0, 0, 0, 0, cast(ubyte) json.length] ~ cast(const(ubyte)[]) json;
    auto t = new MockTransport;
    t.feed(bytes);
    auto reader = new BufferedReader(t);
    auto j = cast(JsonColumn) createColumn("j", "JSON(max_dynamic_paths=10, `a.b` UInt32, SKIP `x.y`)");
    j.readStatePrefix(reader);
    j.readData(reader, 1);
    assert(j.getString(0) == json && j.getQuotedString(0) == `'{"a":{"b":5},"q":[1,2]}'`);

    auto w = new MockTransport;
    auto writer = new BufferedWriter(w);
    j.writeStatePrefix(writer);
    j.writeData(writer);
    writer.flush();
    assert(w.written == bytes);

    // The internal forms (V1 = 0, V2, FLATTENED, V3) can't be read
    auto other = new MockTransport;
    other.feed(cast(const(ubyte)[])[0, 0, 0, 0, 0, 0, 0, 0]);
    assertThrown!ClientException(j.readStatePrefix(new BufferedReader(other)));
    other.feed(cast(const(ubyte)[])[9, 0, 0, 0, 0, 0, 0, 0]);
    assertThrown!ProtocolException(j.readStatePrefix(new BufferedReader(other)));

    // Appends; Nullable(JSON) and JSON inside arrays
    j.appendDefault();
    j.appendString(`{"x":"y"}`);
    assert(j.data[1 .. $] == ["{}", `{"x":"y"}`]);
    foreach (bad; ["{not json", "[1, 2]", "5", ""])
        assertThrown!ClientException(j.appendString(bad), bad);
    assert(j.length == 3);
    // Too deep (as for the server) or out of range: rejected, not a crash or another exception
    import std.array : replicate;

    j.appendString(`{"a":` ~ "[".replicate(maxJsonDepth) ~ "]".replicate(maxJsonDepth) ~ "}"); // 1001 deep
    assertThrown!ClientException(
            j.appendString(`{"a":` ~ "[".replicate(maxJsonDepth + 1) ~ "]".replicate(
            maxJsonDepth + 1) ~ "}"));
    assertThrown!ClientException(j.appendString(`{"a":` ~ "[".replicate(200_000)));
    // 2.097's std.json reads 1e400 as infinity; newer ones throw ConvException, which must not escape
    try
        j.appendString(`{"a":1e400}`);
    catch (ClientException)
    {
    }
    assert(j.length == 4 || j.length == 5);
    j.truncate(4);
    auto n = createColumn("n", "Nullable(JSON)");
    n.appendNull();
    n.appendString("{}");
    assert(n.isNull(0) && n.getString(1) == "{}");
    auto a = createColumn("a", "Array(JSON)");
    a.appendString(`['{"a":1}', '{"b":"it\'s"}']`);
    assert(a.getString(0) == `['{"a":1}','{"b":"it\'s"}']`);
}
