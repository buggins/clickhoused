/++
Server connection settings for integration tests, taken from the environment:
$(UL
    $(LI `CLICKHOUSE_HOST`: `host` or `host:port` (port defaults to 9000). Tests
        that need a server are skipped when it is not set.)
    $(LI `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`: credentials (default: `default`, empty).)
    $(LI `CLICKHOUSE_COMPRESSION`: `none` (default), `lz4` or `zstd`, to run all tests compressed.)
)
+/
module integrationtests.server;

import core.time : seconds;
import std.process : environment;

import clickhoused;

/// Whether a test server is configured.
bool serverConfigured()
{
    return environment.get("CLICKHOUSE_HOST") !is null;
}

/// Connection options for the test server.
ConnectionOptions serverOptions()
{
    import std.algorithm.searching : findSplit;
    import std.conv : to;

    ConnectionOptions options;
    const hostPort = environment.get("CLICKHOUSE_HOST", "localhost");
    if (auto parts = hostPort.findSplit(":"))
    {
        options.host = parts[0];
        options.port = parts[2].to!ushort;
    }
    else
        options.host = hostPort;
    options.user = environment.get("CLICKHOUSE_USER", "default");
    options.password = environment.get("CLICKHOUSE_PASSWORD", "");
    options.receiveTimeout = 30.seconds; // fail fast instead of hanging
    options.compression = environment.get("CLICKHOUSE_COMPRESSION", "none").to!Compression;
    return options;
}

/// Opens a connection to the test server.
Connection connectToServer()
{
    return new Connection(serverOptions());
}
