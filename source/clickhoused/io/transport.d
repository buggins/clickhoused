/++
Byte-stream transport abstraction.

A `Transport` is one open, bidirectional byte stream to the server: a Phobos
socket, a vibe.d connection, a TLS stream, or an in-memory mock in tests.
Higher layers never touch sockets directly; they read and write through this
interface (see `clickhoused.io.buffer`).

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.io.transport;

import core.time : Duration;

/// One open byte stream to the server.
interface Transport
{
    /++
    Reads at least one byte into `buffer`, blocking until data is available.

    Returns: the number of bytes read, or 0 if the peer closed the stream.
    Throws: `clickhoused.exception.ConnectionException` on network errors and timeouts.
    +/
    size_t read(ubyte[] buffer) @safe;

    /++
    Writes all of `data`, blocking until it has been handed to the network.

    Throws: `clickhoused.exception.ConnectionException` on network errors and timeouts.
    +/
    void write(const(ubyte)[] data) @safe;

    /// Closes the stream. Calling it more than once is allowed.
    void close() @safe nothrow;

    /// Whether the stream is open.
    bool connected() const @safe nothrow;

    /++
    Sets the timeouts for subsequent reads and writes.

    Params:
        receive = maximum time a `read` may wait for data; `Duration.zero` means no limit.
        send = maximum time a `write` may block; `Duration.zero` means no limit.
    +/
    void setTimeouts(Duration receive, Duration send) @safe;
}

/++
Opens a new transport to `host`:`port`, giving up after `connectTimeout`.

Pass one in `clickhoused.settings.ConnectionOptions.transportFactory` to
replace the I/O backend's own connect logic, e.g. for Unix sockets, proxies or
tests.
+/
alias TransportFactory = Transport delegate(string host, ushort port, Duration connectTimeout) @safe;
