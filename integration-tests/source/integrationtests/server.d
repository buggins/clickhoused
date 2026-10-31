/++
Server connection settings for integration tests, taken from the environment:
$(UL
    $(LI `CLICKHOUSE_HOST`: `host` or `host:port` (port defaults to 9000, or 9440
        with TLS). Tests that need a server are skipped when it is not set.)
    $(LI `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`: credentials (default: `default`, empty).)
    $(LI `CLICKHOUSE_COMPRESSION`: `none` (default), `lz4` or `zstd`, to run all tests compressed.)
    $(LI `CLICKHOUSE_SECURE`: `1` to run all tests over TLS. Then `CLICKHOUSE_TLS_CA` names the
        CA file that signed the server certificate (default: the system store), and the
        TLS-specific tests run too. They use `CLICKHOUSE_TLS_DIR`, the directory with the test
        certificates (`other-ca.pem`, `client.pem`, `client.key`), and `CLICKHOUSE_TLS_CERT_USER`,
        a user that logs in with the client certificate (both optional).)
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

/// Whether the tests run over TLS (`CLICKHOUSE_SECURE=1`).
bool tlsConfigured()
{
    return environment.get("CLICKHOUSE_SECURE", "") == "1";
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
    options.secure = tlsConfigured();
    options.tls.caFile = environment.get("CLICKHOUSE_TLS_CA", "");
    return options;
}

/// Opens a connection to the test server.
Connection connectToServer()
{
    return new Connection(serverOptions());
}
