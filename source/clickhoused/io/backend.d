/++
I/O backend selection: thread mode (Phobos sockets) or fiber mode (vibe-core).

An `IoBackend` provides everything that may block. In this version it only
opens connections; locks, semaphores and sleeping will be added together with
the connection pool.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.io.backend;

import core.time : Duration;

import clickhoused.exception : ClientException;
import clickhoused.io.transport : Transport;

/// Which I/O backend a connection uses.
enum IoMode
{
    /// Choose automatically. Currently always `phobos`; once fiber mode is
    /// implemented, `vibe` will be chosen when running inside a vibe.d task.
    auto_,
    /// Blocking Phobos sockets, for ordinary threads.
    phobos,
    /// vibe-core sockets, for vibe.d fibers. Not implemented yet.
    vibe,
}

/// Everything that may block, implemented for one concurrency model.
interface IoBackend
{
    /// Short backend name, e.g. `"phobos"`.
    @property string name() const @safe pure nothrow;

    /++
    Opens a connection to `host`:`port`.

    Throws: `clickhoused.exception.ConnectionException` on failure or timeout.
    +/
    Transport connect(string host, ushort port, Duration timeout) @safe;
}

/++
Returns the backend for `mode`.

Throws: `ClientException` if `mode` is `IoMode.vibe`, which is not implemented yet.
+/
IoBackend backendFor(IoMode mode) @safe
{
    import clickhoused.io.phobos : PhobosBackend;

    final switch (mode)
    {
    case IoMode.auto_:
    case IoMode.phobos:
        return new PhobosBackend;
    case IoMode.vibe:
        throw new ClientException("IoMode.vibe is not implemented yet");
    }
}

///
@safe unittest
{
    import std.exception : assertThrown;

    assert(backendFor(IoMode.auto_).name == "phobos");
    assertThrown!ClientException(backendFor(IoMode.vibe));
}
