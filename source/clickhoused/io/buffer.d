/++
Buffered reader and writer over a `Transport`, with the primitive encodings of
the ClickHouse native protocol:
$(UL
    $(LI unsigned LEB128 variable-length integers (`UVarInt`);)
    $(LI fixed-size little-endian integers and floats;)
    $(LI strings: a `UVarInt` length followed by the bytes.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.io.buffer;

import std.traits : isFloatingPoint, isIntegral, isSomeChar;

import clickhoused.exception : ConnectionException, ProtocolException;
import clickhoused.io.transport : Transport;

/// Default size of the read and write buffers.
enum size_t defaultBufferSize = 64 * 1024;

/// Default limit for a single string received from the server (1 GiB).
enum size_t defaultMaxStringLength = 1024 * 1024 * 1024;

/++
Storage for decoded strings: values are carved out of shared buffers, so
decoding a column takes one allocation per buffer instead of one per value.
The buffers start at `firstChunkSize` bytes and double up to `chunkSize`, so
a column with little text wastes little; values longer than `chunkSize / 4`
get their own allocation.

A slice handed out keeps its whole buffer alive. The arena never writes to a
region again once handed out, which is what makes the slices immutable.
+/
package(clickhoused) struct StringArena
{
    /// Size of the largest shared buffers.
    enum size_t chunkSize = 64 * 1024;
    /// Size of the first buffer.
    enum size_t firstChunkSize = 4 * 1024;

    private ubyte[] chunk;
    private size_t used;

    /// A fresh region of `length` bytes, to be filled by the caller.
    ubyte[] take(size_t length) @safe pure nothrow
    {
        import std.array : uninitializedArray;

        if (length > chunkSize / 4)
            return uninitializedArray!(ubyte[])(length);
        if (chunk.length - used < length)
        {
            size_t size = chunk.length ? chunk.length * 2 : firstChunkSize;
            if (size > chunkSize)
                size = chunkSize;
            while (size < length)
                size *= 2;
            chunk = uninitializedArray!(ubyte[])(size);
            used = 0;
        }
        auto region = chunk[used .. used + length];
        used += length;
        return region;
    }
}

/// True for the types that `BufferedReader.readFixed` and `BufferedWriter.writeFixed` accept.
enum isFixedWireType(T) = isIntegral!T || isFloatingPoint!T || is(T == bool) || isSomeChar!T;

/// Reads protocol primitives from a `Transport` through an internal buffer.
final class BufferedReader
{
    private Transport transport;
    private ubyte[] buffer;
    private size_t pos;
    private size_t end;

    /// Strings longer than this are rejected with a `ProtocolException`.
    size_t maxStringLength = defaultMaxStringLength;

    /++
    Creates a reader.

    Params:
        transport = stream to read from.
        bufferSize = size of the internal buffer.
    +/
    this(Transport transport, size_t bufferSize = defaultBufferSize) @safe
    {
        assert(bufferSize > 0);
        this.transport = transport;
        buffer = new ubyte[bufferSize];
    }

    /// Number of bytes already received and buffered but not consumed yet.
    @property size_t buffered() const @safe pure nothrow
    {
        return end - pos;
    }

    /++
    Fills `dst` completely.

    Throws: `ConnectionException` if the stream ends first or on network errors.
    +/
    void readExact(scope ubyte[] dst) @safe
    {
        while (dst.length)
        {
            if (pos == end)
            {
                // Large reads go straight to the destination, bypassing the buffer.
                if (dst.length >= buffer.length)
                {
                    const n = fillFrom(dst);
                    dst = dst[n .. $];
                    continue;
                }
                end = fillFrom(buffer);
                pos = 0;
            }
            const n = dst.length < end - pos ? dst.length : end - pos;
            dst[0 .. n] = buffer[pos .. pos + n];
            pos += n;
            dst = dst[n .. $];
        }
    }

    /// Reads one byte.
    ubyte readByte() @safe
    {
        if (pos == end)
        {
            end = fillFrom(buffer);
            pos = 0;
        }
        return buffer[pos++];
    }

    /++
    Reads an unsigned LEB128 variable-length integer (at most 10 bytes).

    Throws: `ProtocolException` if the encoding is longer than 10 bytes.
    +/
    ulong readUVarInt() @safe
    {
        ulong result;
        foreach (i; 0 .. 10)
        {
            const b = readByte();
            result |= cast(ulong)(b & 0x7F) << (7 * i);
            if ((b & 0x80) == 0)
                return result;
        }
        throw new ProtocolException("Variable-length integer is longer than 10 bytes");
    }

    /// Reads a fixed-size little-endian value.
    T readFixed(T)() @safe if (isFixedWireType!T)
    {
        ubyte[T.sizeof] bytes;
        readExact(bytes[]);
        return fromLittleEndian!T(bytes);
    }

    /++
    Reads a `UVarInt` length followed by that many bytes, as a string.

    The content is not validated as UTF-8: ClickHouse strings are arbitrary bytes.

    Throws: `ProtocolException` if the length exceeds `maxStringLength`.
    +/
    string readString() @safe
    {
        return cast(string) readBytes();
    }

    /++
    Reads a length-prefixed string into `arena`: short strings share its
    buffers, so a column of many values needs few allocations.

    Throws: `ProtocolException` if the length exceeds `maxStringLength`.
    +/
    string readString(ref StringArena arena) @safe
    {
        const len = readUVarInt();
        if (len > maxStringLength)
            throw new ProtocolException("String length exceeds the limit");
        auto bytes = arena.take(cast(size_t) len);
        readExact(bytes);
        return (() @trusted => cast(string) bytes)(); // the arena never hands out or writes these bytes again
    }

    /// Like `readString`, but returns the raw bytes.
    immutable(ubyte)[] readBytes() @safe
    {
        const len = readUVarInt();
        if (len > maxStringLength)
            throw new ProtocolException("String length exceeds the limit");
        auto data = new ubyte[cast(size_t) len];
        readExact(data);
        return (() @trusted => cast(immutable(ubyte)[]) data)(); // data is unique: just allocated
    }

    private size_t fillFrom(scope ubyte[] dst) @safe
    {
        const n = transport.read(dst);
        if (n == 0)
            throw new ConnectionException("Connection closed by the server");
        return n;
    }
}

/// Writes protocol primitives to a `Transport` through an internal buffer.
/// Nothing reaches the network until `flush` is called or the buffer fills up.
final class BufferedWriter
{
    private Transport transport;
    private ubyte[] buffer;
    private size_t used;

    /++
    Creates a writer.

    Params:
        transport = stream to write to.
        bufferSize = size of the internal buffer.
    +/
    this(Transport transport, size_t bufferSize = defaultBufferSize) @safe
    {
        assert(bufferSize > 0);
        this.transport = transport;
        buffer = new ubyte[bufferSize];
    }

    /// Appends raw bytes.
    void writeBytes(scope const(ubyte)[] data) @safe
    {
        if (data.length > buffer.length - used)
        {
            flush();
            if (data.length >= buffer.length)
            {
                transport.write(data);
                return;
            }
        }
        buffer[used .. used + data.length] = data[];
        used += data.length;
    }

    /// Appends one byte.
    void writeByte(ubyte b) @safe
    {
        if (used == buffer.length)
            flush();
        buffer[used++] = b;
    }

    /// Appends an unsigned LEB128 variable-length integer.
    void writeUVarInt(ulong value) @safe
    {
        do
        {
            ubyte b = value & 0x7F;
            value >>= 7;
            if (value)
                b |= 0x80;
            writeByte(b);
        }
        while (value);
    }

    /// Appends a fixed-size little-endian value.
    void writeFixed(T)(T value) @safe if (isFixedWireType!T)
    {
        auto bytes = toLittleEndian(value);
        writeBytes(bytes[]);
    }

    /// Appends a `UVarInt` length followed by the bytes of `s`.
    void writeString(scope const(char)[] s) @safe
    {
        writeUVarInt(s.length);
        writeBytes(cast(const(ubyte)[]) s);
    }

    /// Sends all buffered bytes to the transport.
    void flush() @safe
    {
        if (used)
        {
            transport.write(buffer[0 .. used]);
            used = 0;
        }
    }
}

/// Decodes a little-endian value of type `T`.
T fromLittleEndian(T)(const ubyte[T.sizeof] bytes) @safe pure nothrow @nogc if (isFixedWireType!T)
{
    import std.bitmanip : littleEndianToNative;

    static if (is(T == bool))
        return bytes[0] != 0;
    else
        return littleEndianToNative!T(bytes);
}

/// Encodes `value` as little-endian bytes.
ubyte[T.sizeof] toLittleEndian(T)(T value) @safe pure nothrow @nogc if (isFixedWireType!T)
{
    import std.bitmanip : nativeToLittleEndian;

    static if (is(T == bool))
        return [value ? 1 : 0];
    else
        return nativeToLittleEndian(value);
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
    writer.flush();

    transport.feed(transport.written); // read back what was written
    auto reader = new BufferedReader(transport);
    assert(reader.readUVarInt() == 300);
    assert(reader.readFixed!int() == -2);
    assert(reader.readString() == "hello");
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

    transport.feed(transport.written);
    auto reader = new BufferedReader(transport);
    assert(reader.readUVarInt() == 0);
    assert(reader.readUVarInt() == 127);
    assert(reader.readUVarInt() == 128);
    assert(reader.readUVarInt() == ulong.max);
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.io.mock : MockTransport;

    // Too-long varint, oversized string and truncated input are rejected
    auto transport = new MockTransport;
    transport.feed([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]);
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
    import clickhoused.io.mock : MockTransport;

    // Data split into 1-byte chunks and reads larger than the buffer
    auto payload = new ubyte[1000];
    foreach (i, ref b; payload)
        b = cast(ubyte) i;
    auto transport = new MockTransport;
    transport.maxChunk = 1;
    transport.feed(payload);
    auto reader = new BufferedReader(transport, 16);
    auto head = new ubyte[10];
    reader.readExact(head);
    assert(head == payload[0 .. 10]);
    auto rest = new ubyte[990];
    reader.readExact(rest);
    assert(rest == payload[10 .. $]);

    // Writes larger than the buffer
    transport = new MockTransport;
    auto writer = new BufferedWriter(transport, 16);
    writer.writeByte(1);
    writer.writeBytes(payload);
    writer.flush();
    assert(transport.written.length == 1001 && transport.written[1 .. $] == payload);
}

@safe unittest
{
    // Little-endian helpers
    assert(toLittleEndian!uint(0x01020304) == [4, 3, 2, 1]);
    assert(fromLittleEndian!short([0xFE, 0xFF]) == -2);
    assert(fromLittleEndian!double(toLittleEndian(1.5)) == 1.5);
    assert(toLittleEndian(true) == [1]);
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
