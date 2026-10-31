/++
Native ClickHouse client library for D.

clickhoused talks to ClickHouse over the native TCP protocol and works both
with blocking Phobos sockets (ordinary threads) and with vibe-core sockets
(vibe.d fibers).

This is an unofficial project, not affiliated with ClickHouse, Inc.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors:   Vadim Lopatin
+/
module clickhoused;

public import clickhoused.block;
public import clickhoused.compress.frame : Compression, zstdAvailable;
public import clickhoused.connection;
public import clickhoused.exception;
public import clickhoused.insert;
public import clickhoused.literal;
public import clickhoused.mapping;
public import clickhoused.pool;
public import clickhoused.io.backend : IoMode;
public import clickhoused.io.openssl : loadOpenSsl;
public import clickhoused.io.tls : TlsOptions;
public import clickhoused.io.transport : Transport, TransportFactory;
public import clickhoused.protocol.packets : ProfileInfo, Progress, ServerInfo;
public import clickhoused.settings;
public import clickhoused.types;

/// Library version, reported to the server in the client Hello packet.
enum uint clickhousedVersionMajor = 0;
/// ditto
enum uint clickhousedVersionMinor = 3;
/// ditto
enum uint clickhousedVersionPatch = 0;

/// Library version as a string, e.g. `"0.3.0"`.
enum string clickhousedVersion = versionString(clickhousedVersionMajor,
            clickhousedVersionMinor, clickhousedVersionPatch);

/// Client name reported to the server in the client Hello packet.
enum string clickhousedClientName = "clickhoused";

version (Have_vibe_core)
    private enum bool hasVibeCore = true;
else
    private enum bool hasVibeCore = false;

/++
True when vibe-core support is compiled in.

dub defines `Have_vibe_core` when vibe-core is anywhere in the application's
dependency graph. clickhoused then supports fiber mode in addition to the
always-available thread mode.
+/
enum bool clickhousedHasVibe = hasVibeCore;

private string versionString(uint major, uint minor, uint patch) pure @safe
{
    import std.conv : to;

    return major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
}

///
@safe unittest
{
    assert(clickhousedVersion == "0.3.0");
    assert(clickhousedClientName == "clickhoused");
}

@safe unittest
{
    assert(versionString(1, 22, 333) == "1.22.333");
}
