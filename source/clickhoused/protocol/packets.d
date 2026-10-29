/++
Encoding and decoding of native protocol packets (except data blocks, see
`clickhoused.block`).

All functions take the effective protocol revision of the connection and
include exactly the fields that revision defines.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.protocol.packets;

import clickhoused.exception : ClientException, ServerException;
import clickhoused.io.buffer : BufferedReader, BufferedWriter;
import clickhoused.protocol.codes;

/// Client identity sent in the handshake and with every query.
struct ClientIdentity
{
    /// Client name shown in `system.processes` and query logs.
    string name;
    /// Client major version.
    ulong versionMajor;
    /// Client minor version.
    ulong versionMinor;
    /// Client patch version.
    ulong versionPatch;
}

/// Server information received in the handshake.
struct ServerInfo
{
    /// Server name, e.g. `"ClickHouse"`.
    string name;
    /// Server major version.
    ulong versionMajor;
    /// Server minor version.
    ulong versionMinor;
    /// Server patch version.
    ulong versionPatch;
    /// Server protocol revision.
    ulong revision;
    /// Server default timezone, e.g. `"UTC"`.
    string timezone;
    /// Server display name (the host name by default).
    string displayName;
}

/// Query progress counters. The server sends increments; `QueryResult`
/// accumulates them.
struct Progress
{
    /// Rows read.
    ulong readRows;
    /// Bytes read (uncompressed).
    ulong readBytes;
    /// Estimated total rows to read.
    ulong totalRowsToRead;
    /// Rows written (INSERT).
    ulong writtenRows;
    /// Bytes written (INSERT).
    ulong writtenBytes;
    /// Elapsed server time in nanoseconds.
    ulong elapsedNs;

    /// Adds the counters of `increment`.
    void add(const Progress increment) @safe pure nothrow @nogc
    {
        readRows += increment.readRows;
        readBytes += increment.readBytes;
        totalRowsToRead += increment.totalRowsToRead;
        writtenRows += increment.writtenRows;
        writtenBytes += increment.writtenBytes;
        elapsedNs += increment.elapsedNs;
    }
}

/// Query profiling summary.
struct ProfileInfo
{
    /// Rows in the result.
    ulong rows;
    /// Blocks in the result.
    ulong blocks;
    /// Bytes in the result.
    ulong bytes;
    /// Whether a LIMIT was applied.
    bool appliedLimit;
    /// Number of rows the result would have without LIMIT.
    ulong rowsBeforeLimit;
    /// Whether `rowsBeforeLimit` was calculated.
    bool calculatedRowsBeforeLimit;
}

/++
Writes the client Hello packet.

Throws: `ClientException` if `database`, `user` or `password` contain ASCII
control characters, which the server rejects.
+/
void writeHello(BufferedWriter w, const ClientIdentity client, string database, string user, string password) @safe
{
    foreach (value; [database, user, password])
        foreach (char c; value)
            if (c < 0x20 || c == 0x7F)
                throw new ClientException("Database, user and password must not contain ASCII control characters");

    w.writeUVarInt(ClientPacket.hello);
    w.writeString(client.name);
    w.writeUVarInt(client.versionMajor);
    w.writeUVarInt(client.versionMinor);
    w.writeUVarInt(Revision.client);
    w.writeString(database);
    w.writeString(user);
    w.writeString(password);
}

/++
Reads the body of the server Hello packet (after the packet code).

The server includes the fields defined by the client's revision, so the
optional fields depend on the smaller of `Revision.client` and the server's
revision.
+/
ServerInfo readServerHello(BufferedReader r) @safe
{
    ServerInfo info;
    info.name = r.readString();
    info.versionMajor = r.readUVarInt();
    info.versionMinor = r.readUVarInt();
    info.revision = r.readUVarInt();
    const revision = info.revision < Revision.client ? info.revision : Revision.client;
    if (revision >= Revision.withServerTimezone)
        info.timezone = r.readString();
    if (revision >= Revision.withServerDisplayName)
        info.displayName = r.readString();
    if (revision >= Revision.withVersionPatch)
        info.versionPatch = r.readUVarInt();
    else
        info.versionPatch = info.revision;
    return info;
}

/// Writes the addendum sent after receiving the server Hello.
void writeAddendum(BufferedWriter w, ulong revision, string quotaKey) @safe
{
    if (revision >= Revision.withAddendum)
        w.writeString(quotaKey);
}

/++
Writes a Query packet (without the trailing empty Data packet).

Params:
    w = output.
    revision = effective protocol revision.
    client = client identity for the client info section.
    queryId = query ID; empty lets the server generate one.
    query = SQL text.
    compressed = whether data blocks are sent compressed (network compression).
    settings = query settings as name/value strings. They are sent with the
        IMPORTANT flag, so the server rejects unknown names instead of
        ignoring them.
    parameters = query parameters for `{name:Type}` placeholders.
    quotaKey = quota key.
+/
void writeQuery(BufferedWriter w, ulong revision, const ClientIdentity client, string queryId,
        string query, bool compressed, const string[string] settings, const string[string] parameters,
        string quotaKey) @safe
{
    w.writeUVarInt(ClientPacket.query);
    w.writeString(queryId);
    if (revision >= Revision.withClientInfo)
        writeClientInfo(w, revision, client, quotaKey);

    if (revision < Revision.withSettingsSerializedAsStrings && settings.length)
        throw new ClientException("The server is too old to receive query settings");
    foreach (name, value; settings)
    {
        w.writeString(name);
        w.writeUVarInt(settingFlagImportant);
        w.writeString(value);
    }
    w.writeString(""); // end of settings

    if (revision >= Revision.withInterserverSecret)
        w.writeString(""); // no inter-server secret
    w.writeUVarInt(QueryStage.complete);
    w.writeUVarInt(compressed ? 1 : 0);
    w.writeString(query);

    if (revision >= Revision.withParameters)
    {
        foreach (name, value; parameters)
        {
            w.writeString(name);
            w.writeUVarInt(settingFlagCustom);
            w.writeString(quoteParameter(value));
        }
        w.writeString(""); // end of parameters
    }
    else if (parameters.length)
        throw new ClientException("The server is too old to support query parameters");
}

/// Writes a Ping packet.
void writePing(BufferedWriter w) @safe
{
    w.writeUVarInt(ClientPacket.ping);
}

/// Writes the header of a Data packet; the block follows.
void writeDataHeader(BufferedWriter w, string tableName = "") @safe
{
    w.writeUVarInt(ClientPacket.data);
    w.writeString(tableName);
}

/// Reads the body of an Exception packet, including nested exceptions.
ServerException readException(BufferedReader r) @safe
{
    const code = r.readFixed!int();
    const name = r.readString();
    const message = r.readString();
    const stackTrace = r.readString();
    const hasNested = r.readFixed!bool();
    auto nested = hasNested ? readException(r) : null;
    return new ServerException(code, name, message, stackTrace, nested);
}

/// Reads the body of a Progress packet.
Progress readProgress(BufferedReader r, ulong revision) @safe
{
    Progress p;
    p.readRows = r.readUVarInt();
    p.readBytes = r.readUVarInt();
    p.totalRowsToRead = r.readUVarInt();
    if (revision >= Revision.withClientWriteInfo)
    {
        p.writtenRows = r.readUVarInt();
        p.writtenBytes = r.readUVarInt();
    }
    if (revision >= Revision.withServerQueryTimeInProgress)
        p.elapsedNs = r.readUVarInt();
    return p;
}

/// Reads the body of a ProfileInfo packet.
ProfileInfo readProfileInfo(BufferedReader r) @safe
{
    ProfileInfo p;
    p.rows = r.readUVarInt();
    p.blocks = r.readUVarInt();
    p.bytes = r.readUVarInt();
    p.appliedLimit = r.readFixed!bool();
    p.rowsBeforeLimit = r.readUVarInt();
    p.calculatedRowsBeforeLimit = r.readFixed!bool();
    return p;
}

private enum ulong settingFlagImportant = 0x01;
private enum ulong settingFlagCustom = 0x02;

private void writeClientInfo(BufferedWriter w, ulong revision, const ClientIdentity client, string quotaKey) @safe
{
    w.writeFixed!ubyte(QueryKind.initialQuery);
    w.writeString(""); // initial user
    w.writeString(""); // initial query ID
    w.writeString("0.0.0.0:0"); // initial address
    if (revision >= Revision.withInitialQueryStartTime)
        w.writeFixed!ulong(0); // initial query start time, filled in by the server
    w.writeFixed!ubyte(ClientInterface.tcp);
    w.writeString(osUser());
    w.writeString(hostName());
    w.writeString(client.name);
    w.writeUVarInt(client.versionMajor);
    w.writeUVarInt(client.versionMinor);
    w.writeUVarInt(Revision.client);
    if (revision >= Revision.withQuotaKeyInClientInfo)
        w.writeString(quotaKey);
    if (revision >= Revision.withDistributedDepth)
        w.writeUVarInt(0);
    if (revision >= Revision.withVersionPatch)
        w.writeUVarInt(client.versionPatch);
    if (revision >= Revision.withOpenTelemetry)
        w.writeFixed!ubyte(0); // no trace context
    if (revision >= Revision.withParallelReplicas)
    {
        w.writeUVarInt(0); // collaborate with initiator
        w.writeUVarInt(0); // count of participating replicas
        w.writeUVarInt(0); // number of current replica
    }
}

/// Formats a query parameter value as a quoted SQL string literal, the form
/// the server unquotes when reading parameters.
private string quoteParameter(string value) @safe pure
{
    string s = "'";
    foreach (char c; value)
    {
        switch (c)
        {
        case '\'':
            s ~= `\'`;
            break;
        case '\\':
            s ~= `\\`;
            break;
        default:
            s ~= c;
        }
    }
    return s ~ "'";
}

private string osUser() @safe nothrow
{
    import std.process : environment;

    try
    {
        auto user = environment.get("USER");
        if (user is null)
            user = environment.get("USERNAME");
        return user;
    }
    catch (Exception)
        return null;
}

private string hostName() @safe nothrow
{
    import std.socket : Socket;

    try
        return Socket.hostName;
    catch (Exception)
        return null;
}

///
@safe unittest
{
    import clickhoused.io.mock : MockTransport;

    // A server Hello at revision 54460 (the fields this client receives)
    auto t = new MockTransport;
    auto w = new BufferedWriter(t);
    w.writeString("ClickHouse");
    w.writeUVarInt(26);
    w.writeUVarInt(11);
    w.writeUVarInt(54_492);
    w.writeString("Europe/Lisbon");
    w.writeString("myhost");
    w.writeUVarInt(1);
    w.flush();
    t.feed(t.written);

    const info = readServerHello(new BufferedReader(t));
    assert(info.name == "ClickHouse" && info.versionMajor == 26 && info.versionMinor == 11);
    assert(info.revision == 54_492 && info.timezone == "Europe/Lisbon");
    assert(info.displayName == "myhost" && info.versionPatch == 1);
    assert(t.remaining == 0);
}

@safe unittest
{
    import clickhoused.io.mock : MockTransport;

    // Exception packet with a nested exception
    auto t = new MockTransport;
    auto w = new BufferedWriter(t);
    w.writeFixed!int(62);
    w.writeString("DB::Exception");
    w.writeString("Syntax error");
    w.writeString("");
    w.writeFixed(true);
    w.writeFixed!int(1);
    w.writeString("DB::Inner");
    w.writeString("inner");
    w.writeString("trace");
    w.writeFixed(false);
    w.flush();
    t.feed(t.written);

    const e = readException(new BufferedReader(t));
    assert(e.code == 62 && e.serverMessage == "Syntax error");
    assert(e.nested !is null && e.nested.name == "DB::Inner" && e.nested.serverStackTrace == "trace");
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.io.mock : MockTransport;

    // Query packet layout at the client revision
    auto t = new MockTransport;
    auto w = new BufferedWriter(t);
    const string[string] settings = ["max_threads": "1"];
    const string[string] parameters = ["p": "it's"];
    writeQuery(w, Revision.client, ClientIdentity("test", 1, 2, 3), "qid", "SELECT 1", false, settings,
            parameters, "");
    w.flush();
    t.feed(t.written);

    auto r = new BufferedReader(t);
    assert(r.readUVarInt() == ClientPacket.query);
    assert(r.readString() == "qid");
    // client info
    assert(r.readFixed!ubyte() == QueryKind.initialQuery);
    assert(r.readString() == ""); // initial user
    assert(r.readString() == ""); // initial query ID
    assert(r.readString() == "0.0.0.0:0");
    assert(r.readFixed!ulong() == 0);
    assert(r.readFixed!ubyte() == ClientInterface.tcp);
    r.readString(); // OS user
    r.readString(); // host name
    assert(r.readString() == "test");
    assert(r.readUVarInt() == 1 && r.readUVarInt() == 2 && r.readUVarInt() == Revision.client);
    assert(r.readString() == ""); // quota key
    assert(r.readUVarInt() == 0); // distributed depth
    assert(r.readUVarInt() == 3); // patch
    assert(r.readFixed!ubyte() == 0); // no OpenTelemetry
    foreach (i; 0 .. 3) // parallel replicas fields
        assert(r.readUVarInt() == 0);
    // settings
    assert(r.readString() == "max_threads" && r.readUVarInt() == 1 && r.readString() == "1");
    assert(r.readString() == "");
    assert(r.readString() == ""); // inter-server secret
    assert(r.readUVarInt() == QueryStage.complete);
    assert(r.readUVarInt() == 0); // compression
    assert(r.readString() == "SELECT 1");
    // parameters
    assert(r.readString() == "p" && r.readUVarInt() == 2 && r.readString() == `'it\'s'`);
    assert(r.readString() == "");
    assert(t.remaining == 0);

    assertThrown!ClientException(writeHello(w, ClientIdentity("x"), "db", "us\ner", ""));
}
