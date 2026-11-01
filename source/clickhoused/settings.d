/++
Connection options, and parsing them from a connection string (DSN).

A DSN looks like
`clickhouse://user:password@host1:9000,host2:9000/database?compress=lz4&max_threads=4`.
All parts except the host are optional. See `ConnectionOptions.fromDsn` for
the recognized parameters.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.settings;

import core.time : Duration, seconds;

import clickhoused.compress.frame : Compression;
import clickhoused.exception : ClientException;
import clickhoused.io.backend : IoMode;
import clickhoused.io.tls : TlsOptions;
import clickhoused.io.transport : TransportFactory;

/// Default native protocol port without TLS.
enum ushort defaultPort = 9000;
/// Default native protocol port with TLS (`ConnectionOptions.secure`).
enum ushort defaultSecurePort = 9440;

/// A server address.
struct HostPort
{
    /// Host name or IP address.
    string host;
    /// Native protocol port; 0 means the default (9000, or 9440 with TLS).
    ushort port;

    /// `host:port`, with IPv6 addresses in brackets; just the host when the port is 0 (default).
    string toString() const @safe pure
    {
        import std.algorithm.searching : canFind;
        import std.conv : to;

        const name = host.canFind(':') ? "[" ~ host ~ "]" : host;
        return port ? name ~ ":" ~ port.to!string : name;
    }
}

/// How `ConnectionOptions.hosts` are tried when connecting.
enum HostSelection
{
    /// In the given order: the first host is the primary, the others are fallbacks.
    inOrder,
    /// In random order, spreading connections over the hosts.
    random,
}

/// Options for opening a `clickhoused.connection.Connection`.
struct ConnectionOptions
{
    /// Server host name or IP address. Ignored when `hosts` is set.
    string host = "localhost";
    /++
    Server native protocol port. 0 (the default) means 9000, or 9440 when
    `secure` is set. Ignored when `hosts` is set.
    +/
    ushort port;
    /++
    Several servers (e.g. replicas). Connecting tries them as `hostSelection`
    says and uses the first one that answers; a host that refuses the login is
    not skipped. When empty, `host` and `port` are used.
    +/
    HostPort[] hosts;
    /// Order in which `hosts` are tried.
    HostSelection hostSelection = HostSelection.inOrder;
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
    Connect over TLS. The OpenSSL library (1.1.1 or 3.x) is loaded when the
    first secure connection is made; see `clickhoused.io.openssl.loadOpenSsl`.
    The server certificate and host name are verified unless
    `tls.skipVerify` is set.

    With a `transportFactory`, the transport it returns is wrapped in TLS too;
    leave this off if the factory already returns an encrypted stream.
    +/
    bool secure;
    /// TLS settings, used when `secure` is set: trusted CAs, client certificate, server name.
    TlsOptions tls;

    /++
    In fiber mode, let other tasks run after each block of a query result is
    received, so a large result does not monopolize the event loop. No effect
    in thread mode.
    +/
    bool yieldBetweenBlocks = true;

    /++
    Ask the server for the forms of new types that this client reads fully:
    JSON as text on servers 24.10 and newer (`output_format_native_write_json_as_string`),
    and the flattened form of `Dynamic` on servers 25.6 and newer
    (`output_format_native_use_flattened_dynamic_and_json_serialization`).
    Without them, JSON columns can't be read, and Dynamic values that
    overflow a column's `max_types` arrive binary-encoded and can't be read.
    Settings given explicitly win.
    +/
    bool simpleNativeFormats = true;

    /++
    Settings sent with every query, e.g. `["max_threads": "4"]`.

    Unknown setting names are rejected by the server. Per-query settings
    passed to `Connection.query` override these.
    +/
    string[string] settings;

    /// Client name reported to the server (visible in `system.processes`).
    string clientName = "clickhoused";

    /++
    Parses a connection string:
    `clickhouse://[user[:password]@]host[:port][,host[:port]...][/database][?param=value&...]`.

    User, password and values may be percent-encoded. IPv6 addresses go in
    brackets: `[::1]:9000`. Recognized parameters:
    $(UL
        $(LI `compress`: `none`, `lz4` or `zstd` (`true` means `lz4`);)
        $(LI `zstd_level`;)
        $(LI `connect_timeout`, `send_timeout`, `receive_timeout`: seconds, may be fractional;)
        $(LI `io`: `auto`, `phobos` or `vibe`;)
        $(LI `host_selection`: `in_order` or `random`;)
        $(LI `client_name`, `quota_key`, `yield_between_blocks`, `simple_native_formats` (`true`/`false`);)
        $(LI `secure` (or `tls`): `true`/`1` to connect over TLS; the default port becomes 9440;)
        $(LI `skip_verify`: `true` to accept any server certificate (development only);)
        $(LI `tls_ca_file`: PEM file of trusted CAs, instead of the system store;)
        $(LI `tls_cert_file`, `tls_key_file`: client certificate and key (PEM), for mutual TLS;)
        $(LI `tls_server_name`: name to send (SNI) and verify instead of the host;)
        $(LI `pool_*`: connection pool options, see `clickhoused.pool.PoolOptions.fromDsn`.)
    )
    Any other parameter is sent to the server as a setting, e.g. `max_threads=4`.

    Throws: `ClientException` if the string is malformed or a value is invalid.
    +/
    static ConnectionOptions fromDsn(string dsn) @safe
    {
        import std.algorithm.searching : findSplit, findSplitBefore, startsWith;
        import std.array : split;
        import std.string : indexOf, lastIndexOf;

        enum scheme = "clickhouse://";
        if (!dsn.startsWith(scheme))
            throw new ClientException("A connection string must start with '" ~ scheme ~ "'");
        string rest = dsn[scheme.length .. $];

        string query;
        if (auto q = rest.findSplit("?"))
        {
            rest = q[0];
            query = q[2];
        }
        string path;
        const slash = rest.indexOf('/');
        if (slash >= 0)
        {
            path = rest[slash + 1 .. $];
            rest = rest[0 .. slash];
        }

        string[string] params;
        const at = rest.lastIndexOf('@');
        if (at >= 0)
        {
            const userInfo = rest[0 .. at];
            rest = rest[at + 1 .. $];
            if (auto up = userInfo.findSplit(":"))
            {
                params["user"] = decode(up[0], dsn);
                params["password"] = decode(up[2], dsn);
            }
            else
                params["user"] = decode(userInfo, dsn);
        }
        if (path.length)
            params["database"] = decode(path, dsn);
        foreach (pair; query.split("&"))
        {
            if (pair.length == 0)
                continue;
            if (auto kv = pair.findSplit("="))
                params[decode(kv[0], dsn)] = decode(kv[2], dsn);
            else
                params[decode(pair, dsn)] = "true";
        }

        auto options = fromParams(params);
        if (rest.length == 0)
            throw new ClientException("The connection string has no host");
        options.hosts = null;
        foreach (hostPort; rest.split(","))
            options.hosts ~= parseHostPort(hostPort, dsn);
        if (options.hosts.length == 1)
        {
            options.host = options.hosts[0].host;
            options.port = options.hosts[0].port;
        }
        return options;
    }

    ///
    @safe unittest
    {
        auto o = ConnectionOptions.fromDsn(
                "clickhouse://reader:s%40cret@db1:9001,db2/analytics?compress=lz4&max_threads=4");
        assert(o.user == "reader" && o.password == "s@cret" && o.database == "analytics");
        assert(o.hosts == [HostPort("db1", 9001), HostPort("db2")]); // db2: the default port
        assert(o.compression == Compression.lz4);
        assert(o.settings["max_threads"] == "4");

        auto cloud = ConnectionOptions.fromDsn("clickhouse://user:pass@abc.clickhouse.cloud?secure=true");
        assert(cloud.secure && cloud.effectivePort(cloud.port) == 9440);
    }

    /// The port to connect to for `port`: itself, or the default when it is 0.
    ushort effectivePort(ushort port) const @safe pure nothrow
    {
        return port != 0 ? port : secure ? defaultSecurePort : defaultPort;
    }

    /++
    Builds options from name/value pairs, e.g. the parameters of a ddbc URL.

    Keys: `host`, `port`, `user`, `password`, `database` (or `dbname`), plus
    the parameters described in `fromDsn`. Other keys become server settings.

    Throws: `ClientException` if a value is invalid.
    +/
    static ConnectionOptions fromParams(const string[string] params) @safe
    {
        import std.algorithm.searching : startsWith;
        import std.conv : ConvException, to;

        ConnectionOptions options;
        foreach (key, value; params)
        {
            T parse(T)()
            {
                try
                    return value.to!T;
                catch (ConvException)
                    throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "'");
            }

            switch (key)
            {
            case "host":
                options.host = value;
                break;
            case "port":
                options.port = parse!ushort;
                break;
            case "user":
                options.user = value;
                break;
            case "password":
                options.password = value;
                break;
            case "database":
            case "dbname":
                options.database = value;
                break;
            case "compress":
            case "compression":
                switch (value)
                {
                case "true":
                case "1":
                case "lz4":
                    options.compression = Compression.lz4;
                    break;
                case "false":
                case "0":
                case "none":
                    options.compression = Compression.none;
                    break;
                case "zstd":
                    options.compression = Compression.zstd;
                    break;
                default:
                    throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "'");
                }
                break;
            case "zstd_level":
                options.zstdLevel = parse!int;
                break;
            case "connect_timeout":
                options.connectTimeout = parseSeconds(key, value);
                break;
            case "send_timeout":
                options.sendTimeout = parseSeconds(key, value);
                break;
            case "receive_timeout":
                options.receiveTimeout = parseSeconds(key, value);
                break;
            case "io":
                options.ioMode = value == "auto" ? IoMode.auto_ : parseEnum!IoMode(key, value);
                break;
            case "host_selection":
                options.hostSelection = value == "in_order" ? HostSelection.inOrder
                    : parseEnum!HostSelection(key, value);
                break;
            case "client_name":
                options.clientName = value;
                break;
            case "quota_key":
                options.quotaKey = value;
                break;
            case "yield_between_blocks":
                options.yieldBetweenBlocks = parse!bool;
                break;
            case "simple_native_formats":
                options.simpleNativeFormats = parseFlag(key, value);
                break;
            case "secure":
            case "tls":
                options.secure = parseFlag(key, value);
                break;
            case "skip_verify":
                options.tls.skipVerify = parseFlag(key, value);
                break;
            case "tls_ca_file":
                options.tls.caFile = value;
                break;
            case "tls_cert_file":
                options.tls.certFile = value;
                break;
            case "tls_key_file":
                options.tls.keyFile = value;
                break;
            case "tls_server_name":
                options.tls.serverName = value;
                break;
            default:
                if (!key.startsWith("pool_"))
                    options.settings[key] = value;
            }
        }
        return options;
    }

    ///
    @safe unittest
    {
        auto o = ConnectionOptions.fromParams([
            "host": "ch",
            "port": "9440",
            "dbname": "db",
            "max_threads": "2"
        ]);
        assert(o.host == "ch" && o.port == 9440 && o.database == "db" && o.settings["max_threads"] == "2");
    }
}

@safe unittest
{
    import core.time : msecs;
    import std.exception : assertThrown;

    // Defaults and minimal strings
    auto o = ConnectionOptions.fromDsn("clickhouse://localhost");
    assert(o.host == "localhost" && o.port == 0 && o.user == "default" && o.database == "default");
    assert(!o.secure && o.effectivePort(o.port) == 9000 && o.effectivePort(9001) == 9001);

    // TLS
    o = ConnectionOptions.fromDsn("clickhouse://h1,h2:9441?secure=1&skip_verify=true&tls_ca_file=%2Fetc%2Fca.pem"
            ~ "&tls_cert_file=c.pem&tls_key_file=k.pem&tls_server_name=db.example");
    assert(o.secure && o.tls.skipVerify && o.tls.caFile == "/etc/ca.pem" && o.tls.certFile == "c.pem");
    assert(o.tls.keyFile == "k.pem" && o.tls.serverName == "db.example" && o.settings.length == 0);
    assert(o.effectivePort(o.hosts[0].port) == 9440 && o.effectivePort(o.hosts[1].port) == 9441);
    assert(!ConnectionOptions.fromDsn("clickhouse://h?tls=false").secure);

    // IPv6, timeouts, I/O mode, flags
    o = ConnectionOptions.fromDsn("clickhouse://[::1]:9440/?connect_timeout=0.5&io=phobos&yield_between_blocks=false"
            ~ "&host_selection=random&pool_max=4&compress=zstd&zstd_level=3&simple_native_formats=false");
    assert(o.hosts == [HostPort("::1", 9440)] && o.hosts[0].toString() == "[::1]:9440");
    assert(o.connectTimeout == 500.msecs && o.ioMode == IoMode.phobos && !o.yieldBetweenBlocks);
    assert(!o.simpleNativeFormats && ConnectionOptions.init.simpleNativeFormats);
    assert(o.hostSelection == HostSelection.random && o.compression == Compression.zstd && o.zstdLevel == 3);
    assert("pool_max" !in o.settings && o.database == "default");

    // User without password; percent-encoded database
    o = ConnectionOptions.fromDsn("clickhouse://admin@h/my%20db");
    assert(o.user == "admin" && o.password == "" && o.database == "my db");

    foreach (bad; [
        "http://h", "clickhouse://", "clickhouse://h:notaport", "clickhouse://h:99999",
        "clickhouse://h?compress=x",
        "clickhouse://h?connect_timeout=-1", "clickhouse://h?io=threads", "clickhouse://h?secure=yes",
        "clickhouse://h?skip_verify=2",
        "clickhouse://[::1", "clickhouse://h?x=%zz",
    ])
        assertThrown!ClientException(ConnectionOptions.fromDsn(bad), bad);
}

private HostPort parseHostPort(string text, string dsn) @safe
{
    import std.algorithm.searching : findSplit, startsWith;
    import std.conv : ConvException, to;
    import std.string : indexOf, lastIndexOf;

    string host = text;
    string port;
    if (text.startsWith("["))
    {
        const close = text.indexOf(']');
        if (close < 0)
            throw new ClientException("Invalid host '" ~ text ~ "' in '" ~ dsn ~ "'");
        host = text[1 .. close];
        const after = text[close + 1 .. $];
        if (after.length)
        {
            if (!after.startsWith(":"))
                throw new ClientException("Invalid host '" ~ text ~ "' in '" ~ dsn ~ "'");
            port = after[1 .. $];
        }
    }
    else if (auto hp = text.findSplit(":"))
    {
        host = hp[0];
        port = hp[2];
    }
    if (host.length == 0)
        throw new ClientException("Empty host in '" ~ dsn ~ "'");
    auto result = HostPort(host);
    if (port.length)
    {
        try
            result.port = port.to!ushort;
        catch (ConvException)
            throw new ClientException("Invalid port '" ~ port ~ "' in '" ~ dsn ~ "'");
    }
    return result;
}

private string decode(string text, string dsn) @safe
{
    import std.uri : URIException, decodeComponent;

    try
        return decodeComponent(text);
    catch (URIException)
        throw new ClientException("Invalid percent-encoding in '" ~ dsn ~ "'");
}

private Duration parseSeconds(string key, string value) @safe
{
    import core.time : dur;
    import std.conv : ConvException, to;

    double secondsValue;
    try
        secondsValue = value.to!double;
    catch (ConvException)
        throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "' (seconds expected)");
    if (!(secondsValue >= 0) || secondsValue > 1e9)
        throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "' (seconds expected)");
    return dur!"hnsecs"(cast(long)(secondsValue * 10_000_000));
}

/// Parses `true`/`false`/`1`/`0`.
private bool parseFlag(string key, string value) @safe
{
    switch (value)
    {
    case "true":
    case "1":
        return true;
    case "false":
    case "0":
        return false;
    default:
        throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "' (true or false expected)");
    }
}

private E parseEnum(E)(string key, string value) @safe
{
    import std.conv : ConvException, to;

    try
        return value.to!E;
    catch (ConvException)
        throw new ClientException("Invalid value '" ~ value ~ "' for '" ~ key ~ "'");
}

///
@safe unittest
{
    ConnectionOptions options;
    options.host = "clickhouse.example.com";
    options.user = "reader";
    options.password = "secret";
    options.settings["max_execution_time"] = "60";
    assert(options.effectivePort(options.port) == 9000 && options.database == "default");
}
