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

/// Library version, reported to the server in the client Hello packet.
enum uint clickhousedVersionMajor = 0;
/// ditto
enum uint clickhousedVersionMinor = 0;
/// ditto
enum uint clickhousedVersionPatch = 1;

/// Library version as a string, e.g. `"0.0.1"`.
enum string clickhousedVersion = versionString(clickhousedVersionMajor,
    clickhousedVersionMinor, clickhousedVersionPatch);

/// Client name reported to the server in the client Hello packet.
enum string clickhousedClientName = "clickhoused";

/// True when vibe-core support is compiled in (vibe-core is in the
/// application's dependency graph).
version (Have_vibe_core)
    enum bool clickhousedHasVibe = true;
else
    enum bool clickhousedHasVibe = false;

private string versionString(uint major, uint minor, uint patch) pure @safe
{
    import std.conv : to;

    return major.to!string ~ "." ~ minor.to!string ~ "." ~ patch.to!string;
}

@safe unittest
{
    static assert(clickhousedVersion == "0.0.1");
    static assert(clickhousedClientName == "clickhoused");
}
