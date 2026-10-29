/++
Packet codes and protocol revision numbers of the ClickHouse native protocol.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.protocol.codes;

/// Packets sent by the client.
enum ClientPacket : ulong
{
    /// Handshake: client name, version, revision, database, user, password.
    hello = 0,
    /// Query text, settings and execution parameters.
    query = 1,
    /// A block of data (external tables, INSERT data, or the end-of-data marker).
    data = 2,
    /// Cancel the running query.
    cancel = 3,
    /// Liveness check; the server answers with `ServerPacket.pong`.
    ping = 4,
}

/// Packets sent by the server.
enum ServerPacket : ulong
{
    /// Handshake response: server name, version, revision, timezone, ...
    hello = 0,
    /// A block of result data.
    data = 1,
    /// An error; ends the query.
    exception = 2,
    /// Query progress counters (increments since the previous packet).
    progress = 3,
    /// Response to `ClientPacket.ping`.
    pong = 4,
    /// End of query results.
    endOfStream = 5,
    /// Query profiling summary.
    profileInfo = 6,
    /// A block with totals (`WITH TOTALS`).
    totals = 7,
    /// A block with minimums and maximums (`extremes = 1`).
    extremes = 8,
    /// Response to a tables status request.
    tablesStatusResponse = 9,
    /// A block of server log entries (`send_logs_level`).
    log = 10,
    /// Column descriptions of the INSERT target table.
    tableColumns = 11,
    /// Obsolete part UUIDs packet.
    partUUIDs = 12,
    /// Distributed read task request (server-to-server only).
    readTaskRequest = 13,
    /// A block of profile event counters.
    profileEvents = 14,
}

/// Protocol revisions (versions) and the revision each feature first appeared in.
enum Revision : ulong
{
    /// The revision this client speaks. The effective revision of a
    /// connection is the smaller of this and the server's revision.
    client = 54_460,

    /// Query packet contains client info.
    withClientInfo = 54_032,
    /// Server Hello contains the server timezone.
    withServerTimezone = 54_058,
    /// Client info contains the quota key.
    withQuotaKeyInClientInfo = 54_060,
    /// Server Hello contains the display name.
    withServerDisplayName = 54_372,
    /// Hello contains the patch version.
    withVersionPatch = 54_401,
    /// Progress contains written rows and bytes.
    withClientWriteInfo = 54_420,
    /// Settings are sent as strings with flags.
    withSettingsSerializedAsStrings = 54_429,
    /// Query packet contains the inter-server secret.
    withInterserverSecret = 54_441,
    /// Client info contains the OpenTelemetry trace context.
    withOpenTelemetry = 54_442,
    /// Client info contains the distributed depth.
    withDistributedDepth = 54_448,
    /// Client info contains the initial query start time.
    withInitialQueryStartTime = 54_449,
    /// Server sends profile events packets.
    withIncrementalProfileEvents = 54_451,
    /// Client info contains parallel replicas fields.
    withParallelReplicas = 54_453,
    /// Block columns carry a custom serialization flag.
    withCustomSerialization = 54_454,
    /// Client sends an addendum (quota key) after the handshake.
    withAddendum = 54_458,
    /// Query packet contains query parameters.
    withParameters = 54_459,
    /// Progress contains the elapsed time.
    withServerQueryTimeInProgress = 54_460,
}

/// Query processing stage requested by the client.
enum QueryStage : ulong
{
    /// Only read the columns.
    fetchColumns = 0,
    /// Until an intermediate aggregation state.
    withMergeableState = 1,
    /// Complete execution; what a client normally wants.
    complete = 2,
}

/// `ClientInfo` query kind.
enum QueryKind : ubyte
{
    /// No query.
    noQuery = 0,
    /// A query initiated by a client.
    initialQuery = 1,
    /// A query sent by another server.
    secondaryQuery = 2,
}

/// `ClientInfo` client interface.
enum ClientInterface : ubyte
{
    /// Native TCP protocol.
    tcp = 1,
}
