/++
Exceptions thrown by clickhoused.

All library exceptions derive from `ClickHouseException`, so the library's
errors can be caught with a single `catch`. The subclasses tell apart:
$(UL
    $(LI `ServerException`: the server reported an error. The connection stays usable.)
    $(LI `ConnectionException`: network failure or timeout. The connection is closed.)
    $(LI `ProtocolException`: malformed or unexpected data from the server. The connection is closed.)
    $(LI `ClientException`: invalid use of the library or an unsupported feature.)
)

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.exception;

import std.exception : basicExceptionCtors;

/// Base class of all exceptions thrown by clickhoused.
class ClickHouseException : Exception
{
    ///
    mixin basicExceptionCtors;
}

/// Invalid use of the library, invalid options, or an unsupported feature.
class ClientException : ClickHouseException
{
    ///
    mixin basicExceptionCtors;
}

/// Network failure or timeout. The connection is closed and cannot be reused.
class ConnectionException : ClickHouseException
{
    ///
    mixin basicExceptionCtors;
}

/// The server sent malformed or unexpected data. The connection is closed and
/// cannot be reused.
class ProtocolException : ClickHouseException
{
    ///
    mixin basicExceptionCtors;
}

/++
An error reported by the ClickHouse server, for example a syntax error or an
unknown table.

The connection normally remains usable after this exception. The exception is
errors the server detects while still receiving the query, such as an unknown
setting name or an invalid setting value: the server then closes the
connection, and the next call fails with `ConnectionException`.
+/
class ServerException : ClickHouseException
{
    /// ClickHouse error code, e.g. 62 (`SYNTAX_ERROR`) or 60 (`UNKNOWN_TABLE`).
    int code;
    /// ClickHouse exception class name, e.g. `"DB::Exception"`.
    string name;
    /// Error message as sent by the server; it starts with the exception
    /// class name, e.g. `"DB::Exception: Syntax error: ..."`.
    string serverMessage;
    /// Server-side stack trace; empty unless the server sends it.
    string serverStackTrace;
    /// Nested server exception, if any (sent only by old servers).
    ServerException nested;

    /++
    Creates a server exception.

    Params:
        code = ClickHouse error code.
        name = ClickHouse exception class name.
        serverMessage = error message from the server.
        serverStackTrace = server-side stack trace, may be empty.
        nested = nested exception, may be null.
        file = source file (filled in automatically).
        line = source line (filled in automatically).
    +/
    this(int code, string name, string serverMessage, string serverStackTrace = null,
            ServerException nested = null, string file = __FILE__, size_t line = __LINE__) pure nothrow @safe
    {
        import std.conv : text;

        string msg;
        try
            msg = text("Code: ", code, ". ", serverMessage);
        catch (Exception)
            msg = serverMessage;
        super(msg, file, line);
        this.code = code;
        this.name = name;
        this.serverMessage = serverMessage;
        this.serverStackTrace = serverStackTrace;
        this.nested = nested;
    }
}

///
@safe unittest
{
    auto e = new ServerException(60, "DB::Exception", "DB::Exception: Unknown table expression identifier 'foo'");
    assert(e.code == 60);
    assert(e.msg == "Code: 60. DB::Exception: Unknown table expression identifier 'foo'");

    const ClickHouseException base = e; // all library exceptions share one base class
    assert(base !is null);
}
