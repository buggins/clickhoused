/++
Connection options.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.settings;

import core.time : Duration, seconds;

import clickhoused.compress.frame : Compression;
import clickhoused.io.backend : IoMode;
import clickhoused.io.transport : TransportFactory;

/// Options for opening a `clickhoused.connection.Connection`.
struct ConnectionOptions
{
    /// Server host name or IP address.
    string host = "localhost";
    /// Server native protocol port (9000; 9440 is the usual TLS port).
    ushort port = 9000;
    /// Default database.
    string database = "default";
    /// User name.
    string user = "default";
    /// Password.
    string password;
    /// Quota key, for quotas keyed by client-supplied keys.
    string quotaKey;

    /// Maximum time to establish the TCP connection.
    Duration connectTimeout = 10.seconds;
    /// Maximum time a single socket write may block.
    Duration sendTimeout = 300.seconds;
    /// Maximum time to wait for the next piece of data from the server.
    /// The server sends progress packets while a query runs, so this limits
    /// silence, not total query time.
    Duration receiveTimeout = 300.seconds;

    /++
    Network compression of data blocks in both directions. `Compression.lz4`
    usually pays off for remote servers; for a server on the same host,
    `Compression.none` is faster. `Compression.zstd` needs the `zstd` dub
    configuration.
    +/
    Compression compression = Compression.none;
    /// ZSTD compression level (1 to 22) for data sent to the server and requested from it.
    int zstdLevel = 1;

    /// I/O backend selection.
    IoMode ioMode = IoMode.auto_;
    /// Custom transport factory; overrides the backend's connect logic when set.
    TransportFactory transportFactory;

    /++
    Settings sent with every query, e.g. `["max_threads": "4"]`.

    Unknown setting names are rejected by the server. Per-query settings
    passed to `Connection.query` override these.
    +/
    string[string] settings;

    /// Client name reported to the server (visible in `system.processes`).
    string clientName = "clickhoused";
}

///
@safe unittest
{
    ConnectionOptions options;
    options.host = "clickhouse.example.com";
    options.user = "reader";
    options.password = "secret";
    options.settings["max_execution_time"] = "60";
    assert(options.port == 9000 && options.database == "default");
}
