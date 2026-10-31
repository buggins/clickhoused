/++
TLS-specific integration tests. They run when `CLICKHOUSE_SECURE=1` (see
`integrationtests.server`); every other test then runs over TLS as well.

`integration-tests/tls/start-server.sh` starts a ClickHouse container set up
for these tests, with the certificates from `source/clickhoused/io/testdata`.
+/
module integrationtests.tls;

import std.algorithm.searching : canFind, startsWith;
import std.exception : collectException, enforce;
import std.path : buildPath;
import std.process : environment;

import clickhoused;
import integrationtests.basic : firstBlock;
import integrationtests.server : serverOptions;

/// The connection is encrypted and works; the port defaults to 9440.
void testTlsConnection()
{
    auto conn = new Connection(serverOptions());
    scope (exit)
        conn.close();
    enforce(conn.tlsVersion.startsWith("TLSv1."), "not a TLS connection: '" ~ conn.tlsVersion ~ "'");
    auto block = conn.firstBlock("SELECT toUInt64(42) AS v");
    enforce(block.column!UInt64Column("v").data == [42], "wrong result over TLS");

    auto defaultPort = serverOptions();
    defaultPort.port = 0;
    enforce(defaultPort.effectivePort(defaultPort.port) == 9440, "the TLS default port should be 9440");
}

/// A wrong CA or a wrong server name is rejected; `skipVerify` accepts both.
void testTlsVerification()
{
    auto wrongName = serverOptions();
    wrongName.tls.serverName = "wrong.example";
    auto e = collectException!ConnectionException(new Connection(wrongName));
    enforce(e !is null && e.msg.canFind("verification failed for wrong.example"),
            "a wrong server name should be rejected: " ~ (e is null ? "connected" : e.msg));

    const dir = environment.get("CLICKHOUSE_TLS_DIR", "");
    if (dir.length)
    {
        auto wrongCa = serverOptions();
        wrongCa.tls.caFile = buildPath(dir, "other-ca.pem");
        e = collectException!ConnectionException(new Connection(wrongCa));
        enforce(e !is null && e.msg.canFind("verification failed"),
                "an untrusted server certificate should be rejected: " ~ (e is null ? "connected" : e.msg));
    }

    auto skip = wrongName;
    skip.tls.skipVerify = true;
    auto conn = new Connection(skip);
    scope (exit)
        conn.close();
    conn.ping();
}

/// A user authenticated by its client certificate logs in without a password.
void testTlsCertificateLogin()
{
    const user = environment.get("CLICKHOUSE_TLS_CERT_USER", "");
    const dir = environment.get("CLICKHOUSE_TLS_DIR", "");
    if (user.length == 0 || dir.length == 0)
        return; // not configured for this server

    auto options = serverOptions();
    options.user = user;
    options.password = "";
    options.tls.certFile = buildPath(dir, "client.pem");
    options.tls.keyFile = buildPath(dir, "client.key");
    auto conn = new Connection(options);
    scope (exit)
        conn.close();
    auto block = conn.firstBlock("SELECT currentUser() AS u");
    enforce(block.column!StringColumn("u").getString(0) == user, "logged in as the wrong user");

    // Without the certificate the server refuses the login
    options.tls.certFile = options.tls.keyFile = null;
    auto e = collectException!ServerException(new Connection(options));
    enforce(e !is null, "the certificate user should not log in without its certificate");
}
