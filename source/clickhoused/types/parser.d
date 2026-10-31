/++
Parser for ClickHouse type names such as `Nullable(String)`,
`DateTime64(3, 'UTC')`, `Enum8('a' = 1, 'b' = 2)` or
`Tuple(id UInt64, name String)`.

The server sends the type of every column as a string; the parser turns it
into a `TypeNode` tree that the column factory works from.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.parser;

import clickhoused.exception : ProtocolException;

/// A parsed type: a name with optional arguments, e.g. `FixedString(16)`.
struct TypeNode
{
    /// Type name, e.g. `"FixedString"`.
    string name;
    /// Arguments in parentheses; empty if the type has none.
    TypeArg[] args;

    /// Formats the type back into ClickHouse syntax.
    string toString() const @safe pure
    {
        if (args.length == 0)
            return name;
        string s = name ~ "(";
        foreach (i, ref arg; args)
        {
            if (i)
                s ~= ", ";
            s ~= arg.toString();
        }
        return s ~ ")";
    }
}

/// Kind of a `TypeArg`.
enum TypeArgKind
{
    /// A nested type, e.g. `String` in `Nullable(String)`.
    type,
    /// An integer, e.g. `16` in `FixedString(16)`.
    number,
    /// A quoted string, e.g. `'UTC'` in `DateTime('UTC')`.
    text,
    /// An enum element, e.g. `'a' = 1` in `Enum8('a' = 1)`.
    enumValue,
    /// A named element, e.g. `id UInt64` in `Tuple(id UInt64)`.
    namedType,
}

/// One argument of a `TypeNode`.
struct TypeArg
{
    /// Which fields below are meaningful.
    TypeArgKind kind;
    /// Nested type, for `TypeArgKind.type` and `TypeArgKind.namedType`.
    TypeNode type;
    /// Value, for `TypeArgKind.number` and `TypeArgKind.enumValue`.
    long number;
    /// String, for `TypeArgKind.text`; label, for `TypeArgKind.enumValue`;
    /// element name, for `TypeArgKind.namedType`.
    string text;

    /// Formats the argument back into ClickHouse syntax.
    string toString() const @safe pure
    {
        import std.conv : to;

        final switch (kind)
        {
        case TypeArgKind.type:
            return type.toString();
        case TypeArgKind.number:
            return number.to!string;
        case TypeArgKind.text:
            return quote(text);
        case TypeArgKind.enumValue:
            return quote(text) ~ " = " ~ number.to!string;
        case TypeArgKind.namedType:
            return quoteName(text) ~ " " ~ type.toString();
        }
    }
}

/// An element name as written in a type: in backquotes unless it is a plain identifier.
private string quoteName(string name) @safe pure
{
    bool plain = name.length != 0 && !(name[0] >= '0' && name[0] <= '9');
    foreach (c; name)
        if (!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'))
            plain = false;
    if (plain)
        return name;
    string s = "`";
    foreach (char c; name)
    {
        if (c == '`' || c == '\\')
            s ~= '\\';
        s ~= c;
    }
    return s ~ "`";
}

/++
Parses a ClickHouse type name.

Throws: `ProtocolException` if `typeName` is not a valid type name.
+/
TypeNode parseType(string typeName) @safe pure
{
    auto p = Parser(typeName);
    auto node = p.parseNode();
    p.skipSpaces();
    if (p.pos != typeName.length)
        p.fail("unexpected characters after the type");
    return node;
}

///
@safe pure unittest
{
    auto t = parseType("Nullable(FixedString(16))");
    assert(t.name == "Nullable");
    assert(t.args[0].type.name == "FixedString");
    assert(t.args[0].type.args[0].number == 16);

    auto e = parseType("Enum8('increment' = 1, 'gauge' = 2)");
    assert(e.args[1].kind == TypeArgKind.enumValue);
    assert(e.args[1].text == "gauge" && e.args[1].number == 2);

    assert(parseType("DateTime('Europe/Lisbon')").args[0].text == "Europe/Lisbon");
}

@safe pure unittest
{
    import std.exception : assertThrown;

    // Round trips
    foreach (s; [
        "UInt64", "Array(Nullable(String))", "DateTime64(3, 'UTC')",
        "Tuple(id UInt64, name String)", "Map(String, Array(Tuple(UInt8, Float64)))",
        "Decimal(18, 4)", "Enum16('a' = -1, 'b\\'c' = 300)",
    ])
        assert(parseType(s).toString() == s, s);

    // Spacing is irrelevant; backquoted element names are accepted
    assert(parseType(" Tuple( `my field` UInt8 ,x String ) ").toString() == "Tuple(`my field` UInt8, x String)");
    assert(parseType("Tuple(\n    a UInt8,\n    `1` String)").toString() == "Tuple(a UInt8, `1` String)");

    foreach (bad; [
        "", "(", "Nullable(", "Nullable(String", "Enum8('a' = )", "UInt8)", "1abc", "A('x"
    ])
        assertThrown!ProtocolException(parseType(bad), bad);
}

private string quote(string s) @safe pure
{
    string r = "'";
    foreach (char c; s)
    {
        if (c == '\'' || c == '\\')
            r ~= '\\';
        r ~= c;
    }
    return r ~ "'";
}

private struct Parser
{
    string input;
    size_t pos;

    TypeNode parseNode() @safe pure
    {
        skipSpaces();
        TypeNode node;
        node.name = parseIdentifier();
        skipSpaces();
        if (peek == '(')
        {
            pos++;
            skipSpaces();
            if (peek != ')')
            {
                for (;;)
                {
                    node.args ~= parseArg();
                    skipSpaces();
                    if (peek == ',')
                    {
                        pos++;
                        continue;
                    }
                    break;
                }
            }
            expect(')');
        }
        return node;
    }

    TypeArg parseArg() @safe pure
    {
        skipSpaces();
        TypeArg arg;
        const c = peek;
        if (c == '\'')
        {
            arg.text = parseQuoted();
            skipSpaces();
            if (peek == '=')
            {
                pos++;
                skipSpaces();
                arg.kind = TypeArgKind.enumValue;
                arg.number = parseNumber();
            }
            else
                arg.kind = TypeArgKind.text;
        }
        else if (c == '-' || isDigit(c))
        {
            arg.kind = TypeArgKind.number;
            arg.number = parseNumber();
        }
        else if (c == '`')
        {
            arg.kind = TypeArgKind.namedType;
            arg.text = parseBackquoted();
            arg.type = parseNode();
        }
        else
        {
            // Either a type, or "name Type" (a named tuple element)
            const start = pos;
            const ident = parseIdentifier();
            skipSpaces();
            if (isIdentStart(peek))
            {
                arg.kind = TypeArgKind.namedType;
                arg.text = ident;
                arg.type = parseNode();
            }
            else
            {
                pos = start;
                arg.kind = TypeArgKind.type;
                arg.type = parseNode();
            }
        }
        return arg;
    }

    string parseIdentifier() @safe pure
    {
        const start = pos;
        if (!isIdentStart(peek))
            fail("expected a type name");
        while (pos < input.length && isIdentChar(input[pos]))
            pos++;
        return input[start .. pos];
    }

    long parseNumber() @safe pure
    {
        import std.conv : ConvException, to;

        const start = pos;
        if (peek == '-')
            pos++;
        if (!isDigit(peek))
            fail("expected a number");
        while (pos < input.length && isDigit(input[pos]))
            pos++;
        try
            return input[start .. pos].to!long;
        catch (ConvException)
            fail("number out of range");
        assert(0);
    }

    string parseQuoted() @safe pure
    {
        return parseDelimited('\'');
    }

    string parseBackquoted() @safe pure
    {
        return parseDelimited('`');
    }

    string parseDelimited(char quoteChar) @safe pure
    {
        expect(quoteChar);
        string s;
        for (;;)
        {
            if (pos >= input.length)
                fail("unterminated quoted string");
            const c = input[pos++];
            if (c == '\\')
            {
                if (pos >= input.length)
                    fail("unterminated quoted string");
                s ~= input[pos++];
            }
            else if (c == quoteChar)
            {
                if (peek == quoteChar) // doubled quote
                {
                    s ~= quoteChar;
                    pos++;
                }
                else
                    return s;
            }
            else
                s ~= c;
        }
    }

    void expect(char c) @safe pure
    {
        skipSpaces();
        if (peek != c)
            fail("expected '" ~ c ~ "'");
        pos++;
    }

    void skipSpaces() @safe pure nothrow @nogc
    {
        while (pos < input.length && (input[pos] == ' ' || input[pos] == '\t' || input[pos] == '\n'))
            pos++;
    }

    @property char peek() const @safe pure nothrow @nogc
    {
        return pos < input.length ? input[pos] : '\0';
    }

    noreturn fail(string what) const @safe pure
    {
        import std.conv : to;

        throw new ProtocolException("Invalid type name '" ~ input ~ "' at position " ~ pos.to!string ~ ": " ~ what);
    }
}

private bool isDigit(char c) @safe pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

private bool isIdentStart(char c) @safe pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}

private bool isIdentChar(char c) @safe pure nothrow @nogc
{
    return isIdentStart(c) || isDigit(c);
}
