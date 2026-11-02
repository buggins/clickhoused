/++
Buffered reader and writer (from `dbwire.io.buffer`, re-exported here) and the
primitive encodings of the ClickHouse native protocol, as free functions
called with UFCS (`reader.readUVarInt()`):
$(UL
    $(LI unsigned LEB128 variable-length integers (`UVarInt`);)
    $(LI fixed-size little-endian integers and floats (`readFixed`, `writeFixed`);)
    $(LI strings: a `UVarInt` length followed by the bytes.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.io.buffer;

public import dbwire.io.buffer;

import clickhoused.exception : ProtocolException;

/++
Reads an unsigned LEB128 variable-length integer (at most 10 bytes).

Throws: `ProtocolException` if the encoding is longer than 10 bytes;
`ConnectionException` if the stream ends first.
+/
ulong readUVarInt(BufferedReader reader) @safe
{
    const bytes = reader.window();
    if (bytes.length >= 10)
    {
        // Enough bytes buffered for the longest encoding: decode in place
        ulong result;
        foreach (i, b; bytes[0 .. 10])
        {
            result |= cast(ulong)(b & 0x7F) << (7 * i);
            if ((b & 0x80) == 0)
            {
                reader.consume(i + 1);
                return result;
            }
        }
        throw tooLong();
    }
    ulong result;
    foreach (i; 0 .. 10)
    {
        const b = reader.readByte();
        result |= cast(ulong)(b & 0x7F) << (7 * i);
        if ((b & 0x80) == 0)
            return result;
    }
    throw tooLong();
}

/++
Reads a `UVarInt` length followed by that many bytes, as a string.

The content is not validated as UTF-8: ClickHouse strings are arbitrary bytes.

Throws: `ProtocolException` if the length exceeds `BufferedReader.maxStringLength`.
+/
string readString(BufferedReader reader) @safe
{
    return reader.readExactString(lengthOf(reader.readUVarInt()));
}

/++
Reads a length-prefixed string into `arena`: short strings share its
buffers, so a column of many values needs few allocations.

Throws: `ProtocolException` if the length exceeds `BufferedReader.maxStringLength`.
+/
string readString(BufferedReader reader, ref StringArena arena) @safe
{
    return reader.readExactString(lengthOf(reader.readUVarInt()), arena);
}

/// Like `readString`, but returns the raw bytes.
immutable(ubyte)[] readBytes(BufferedReader reader) @safe
{
    return reader.readExactBytes(lengthOf(reader.readUVarInt()));
}

/// Appends an unsigned LEB128 variable-length integer.
void writeUVarInt(BufferedWriter writer, ulong value) @safe
{
    auto space = writer.reserve(10);
    size_t n;
    do
    {
        ubyte b = value & 0x7F;
        value >>= 7;
        if (value)
            b |= 0x80;
        space[n++] = b;
    }
    while (value);
    writer.commit(n);
}

/// Appends a `UVarInt` length followed by the bytes of `s`.
void writeString(BufferedWriter writer, scope const(char)[] s) @safe
{
    writer.writeUVarInt(s.length);
    writer.writeBytes(cast(const(ubyte)[]) s);
}

/// A received length as `size_t` (lengths beyond `size_t` fail the `maxStringLength` check).
private size_t lengthOf(ulong length) @safe pure nothrow @nogc
{
    return length > size_t.max ? size_t.max : cast(size_t) length;
}

private ProtocolException tooLong() @safe pure nothrow
{
    return new ProtocolException("Variable-length integer is longer than 10 bytes");
}

///
@safe unittest
{
    import clickhoused.io.mock : MockTransport;

    auto transport = new MockTransport;
    auto writer = new BufferedWriter(transport);
    writer.writeUVarInt(300);
    writer.writeFixed!int(-2);
    writer.writeString("hello");
    writer.writeString("ab");
    writer.flush();

    transport.feed(transport.written); // read back what was written
    auto reader = new BufferedReader(transport);
    assert(reader.readUVarInt() == 300);
    assert(reader.readFixed!int() == -2);
    assert(reader.readString() == "hello");
    assert(reader.readBytes() == ['a', 'b']);
}

@safe unittest
{
    import clickhoused.io.mock : MockTransport;

    // UVarInt encodings, boundaries and maximum value
    auto transport = new MockTransport;
    auto writer = new BufferedWriter(transport);
    writer.writeUVarInt(0);
    writer.writeUVarInt(127);
    writer.writeUVarInt(128);
    writer.writeUVarInt(ulong.max);
    writer.flush();
    assert(transport.written == [
        0x00, 0x7F, 0x80, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01
    ]);

    // Decoded both from the buffer (fast path) and byte by byte (near the end of the data)
    foreach (chunk; [size_t.max, 1])
    {
        transport.feed(transport.written);
        transport.maxChunk = chunk;
        auto reader = new BufferedReader(transport);
        assert(reader.readUVarInt() == 0);
        assert(reader.readUVarInt() == 127);
        assert(reader.readUVarInt() == 128);
        assert(reader.readUVarInt() == ulong.max);
    }
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.exception : ConnectionException;
    import clickhoused.io.mock : MockTransport;

    // Too-long varint (both paths), oversized string and truncated input are rejected
    const ubyte[] eleven = [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01];
    auto transport = new MockTransport;
    transport.feed(eleven);
    assertThrown!ProtocolException(new BufferedReader(transport).readUVarInt());
    transport = new MockTransport;
    transport.feed(eleven);
    transport.maxChunk = 1;
    assertThrown!ProtocolException(new BufferedReader(transport).readUVarInt());

    transport = new MockTransport;
    transport.feed([0x05, 'a', 'b']);
    auto reader = new BufferedReader(transport);
    reader.maxStringLength = 4;
    assertThrown!ProtocolException(reader.readString());

    transport = new MockTransport;
    transport.feed([0x05, 'a', 'b']);
    assertThrown!ConnectionException(new BufferedReader(transport).readString());
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.io.mock : MockTransport;

    // Strings read into an arena: short ones share a buffer, long ones get their own, limits still apply
    auto t = new MockTransport;
    auto w = new BufferedWriter(t);
    string[] values = ["", "a", "hello", "x"];
    char[] big;
    big.length = StringArena.chunkSize / 4 + 1;
    big[] = 'b';
    values ~= big.idup;
    foreach (i; 0 .. 2000)
        values ~= "value" ~ cast(char)('0' + i % 10); // more than one buffer
    foreach (v; values)
        w.writeString(v);
    w.flush();
    t.feed(t.written);
    auto r = new BufferedReader(t);
    StringArena arena;
    string[] got;
    foreach (_; values)
        got ~= r.readString(arena);
    assert(got == values);
    assert((() @trusted => got[1].ptr + 1 == got[2].ptr)()); // consecutive short values share a buffer

    auto limited = new MockTransport;
    auto lw = new BufferedWriter(limited);
    lw.writeString("too long");
    lw.flush();
    limited.feed(limited.written);
    auto lr = new BufferedReader(limited);
    lr.maxStringLength = 4;
    assertThrown!ProtocolException(lr.readString(arena));
}
