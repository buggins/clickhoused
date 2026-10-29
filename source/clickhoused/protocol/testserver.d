/++
A scripted ClickHouse server for unit tests: builds server packets and feeds
them to a `MockTransport` that a `Connection` reads from.

Only compiled into unittest builds.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.protocol.testserver;

version (unittest)  : import clickhoused.block : Block, readBlock, writeBlock;
import clickhoused.connection : Connection;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.io.mock : MockTransport;
import clickhoused.io.transport : Transport;
import clickhoused.protocol.codes : Revision, ServerPacket;
import clickhoused.settings : ConnectionOptions;
import clickhoused.types.numeric : UInt8Column;

/++
Builds server output. Packets written with the methods below are buffered
until `send` (or `connect`) hands them to the client's transport.
+/
package(clickhoused) final class ScriptedServer
{
    /// The client's transport; `transport.written` holds what the client sent.
    MockTransport transport;
    /// Writer for server packets.
    BufferedWriter w;
    private MockTransport scratch;

    this() @safe
    {
        transport = new MockTransport;
        scratch = new MockTransport;
        w = new BufferedWriter(scratch);
    }

    /// Server Hello at a revision above the client's.
    void hello() @safe
    {
        w.writeUVarInt(ServerPacket.hello);
        w.writeString("ClickHouse");
        w.writeUVarInt(26);
        w.writeUVarInt(11);
        w.writeUVarInt(54_492);
        w.writeString("UTC");
        w.writeString("test");
        w.writeUVarInt(1);
    }

    /// A packet carrying `block` (data, totals, profile events, ...).
    void block(ServerPacket kind, Block block) @safe
    {
        w.writeUVarInt(kind);
        w.writeString("");
        writeBlock(w, block, Revision.client);
    }

    /// A data packet with one `UInt8` column `x`.
    void dataBlock(ubyte[] values) @safe
    {
        auto b = new Block;
        auto c = new UInt8Column("x", "UInt8");
        c.data = values;
        b.columns = [c];
        b.rows = values.length;
        block(ServerPacket.data, b);
    }

    /// A TableColumns packet, sent before the header of an INSERT.
    void tableColumns() @safe
    {
        w.writeUVarInt(ServerPacket.tableColumns);
        w.writeString("");
        w.writeString("columns format version: 1\n0 columns:\n");
    }

    /// A progress packet.
    void progress(ulong readRows, ulong writtenRows = 0) @safe
    {
        w.writeUVarInt(ServerPacket.progress);
        foreach (v; [readRows, readRows * 8, 0, writtenRows, writtenRows * 8, 1000])
            w.writeUVarInt(v);
    }

    /// An exception packet.
    void exception(int code, string message) @safe
    {
        w.writeUVarInt(ServerPacket.exception);
        w.writeFixed(code);
        w.writeString("DB::Exception");
        w.writeString("DB::Exception: " ~ message);
        w.writeString("");
        w.writeFixed(false);
    }

    /// An end-of-stream packet.
    void endOfStream() @safe
    {
        w.writeUVarInt(ServerPacket.endOfStream);
    }

    /// Hands the buffered packets to the client's transport.
    void send() @safe
    {
        w.flush();
        transport.feed(scratch.written);
        scratch.clearWritten();
    }

    /// Sends the buffered packets (normally `hello`) and connects a client.
    Connection connect() @safe
    {
        send();
        ConnectionOptions options;
        options.transportFactory = (host, port, timeout) => cast(Transport) transport;
        auto conn = new Connection(options);
        transport.clearWritten();
        return conn;
    }

    /// A reader over everything the client has written since the last `clearWritten`.
    BufferedReader clientOutput() @safe
    {
        auto copy = new MockTransport;
        copy.feed(transport.written);
        return new BufferedReader(copy);
    }
}
