/// Smoke tests that need no server: they check that the library links and
/// that the runner was built in the expected I/O configuration.
module integrationtests.smoke;

import std.exception : enforce;

import clickhoused;

/// The library links, and vibe support matches the runner's expectation.
void testLibraryMetadata()
{
    import integrationtests.harness : currentRunner;

    enforce(clickhousedClientName == "clickhoused", "unexpected client name");
    enforce(clickhousedVersion.length > 0, "empty library version");
    if (currentRunner.expectVibe)
        enforce(clickhousedHasVibe, "vibe runner built without vibe-core support");
}
