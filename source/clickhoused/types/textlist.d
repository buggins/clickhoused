/++
Parsing of bracketed lists in ClickHouse's text form, such as the array
`[1, 'a', NULL]` or the tuple `(1, [2, 3])`. Used by the composite columns'
`appendString`.

Copyright: Copyright © 2026, Vadim Lopatin
License:   $(LINK2 https://www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
+/
module clickhoused.types.textlist;

import clickhoused.exception : ClientException;
import clickhoused.types.column : Column;

/// One element of a parsed list.
package struct TextElement
{
    /// What the element looked like in the text.
    enum Kind
    {
        quoted, /// A quoted string; `text` is unescaped.
        composite, /// A nested list (`[...]`, `(...)`, `{...}`); `text` includes the brackets.
        null_, /// The keyword `NULL`.
        bare, /// Anything else, e.g. a number; `text` is trimmed.
    }

    Kind kind; ///
    string text; ///

    /// Appends the element to `column`: NULL as `appendNull`, everything else as `appendString`
    /// (for a Variant column, choosing the alternative by whether the text was quoted).
    void appendTo(Column column) const @safe
    {
        import clickhoused.types.variant : VariantColumn;

        if (kind == Kind.null_)
            column.appendNull();
        else if (auto variant = cast(VariantColumn) column)
            variant.appendTextElement(text, kind == Kind.quoted); // `1` and `'1'` go to different alternatives
        else
            column.appendString(text);
    }
}

/++
Parses `text` as a list enclosed in `open` and `close`, e.g. `'['` and `']'`.
Quoted strings may use backslash escapes or a doubled quote.

Throws: `ClientException` (with a message naming `target`) if the text is
not such a list.
+/
package TextElement[] parseTextList(string text, char open, char close, const Column target, string kind) @safe
{
    auto parser = Parser(text, target, kind);
    return parser.parse(open, close);
}

/++
Parses `text` as a map in ClickHouse's text form: `{key: value, ...}`.

Throws: `ClientException` (with a message naming `target`) if the text is
not such a map.
+/
package TextElement[2][] parseTextPairs(string text, const Column target) @safe
{
    auto parser = Parser(text, target, "a map");
    return parser.parsePairs();
}

private struct Parser
{
    string text;
    const Column target; // for error messages
    string kind; // "an array", "a tuple"
    size_t pos;

    TextElement[] parse(char open, char close) @safe
    {
        TextElement[] elements;
        skipSpaces();
        expect(open);
        skipSpaces();
        if (peek() == close)
            pos++;
        else
        {
            for (;;)
            {
                elements ~= element([',', close]);
                skipSpaces();
                const c = next();
                if (c == close)
                    break;
                if (c != ',')
                    throw error();
            }
        }
        skipSpaces();
        if (pos != text.length)
            throw error();
        return elements;
    }

    /// One element; a bare token ends at any of `stops`.
    private TextElement element(scope const char[] stops) @safe
    {
        skipSpaces();
        const c = peek();
        if (c == '\'')
            return TextElement(TextElement.Kind.quoted, quoted());
        if (c == '[' || c == '(' || c == '{')
            return TextElement(TextElement.Kind.composite, nested());
        const start = pos;
        while (pos < text.length && !isStop(text[pos], stops))
            pos++;
        auto token = text[start .. pos];
        while (token.length && (token[$ - 1] == ' ' || token[$ - 1] == '\t' || token[$ - 1] == '\n'))
            token = token[0 .. $ - 1];
        if (token.length == 0)
            throw error();
        return TextElement(token == "NULL" ? TextElement.Kind.null_ : TextElement.Kind.bare, token);
    }

    /// Parses `{key: value, ...}`.
    TextElement[2][] parsePairs() @safe
    {
        TextElement[2][] pairs;
        skipSpaces();
        expect('{');
        skipSpaces();
        if (peek() == '}')
            pos++;
        else
        {
            for (;;)
            {
                const key = element([':']);
                skipSpaces();
                expect(':');
                const value = element([',', '}']);
                pairs ~= [key, value];
                skipSpaces();
                const c = next();
                if (c == '}')
                    break;
                if (c != ',')
                    throw error();
            }
        }
        skipSpaces();
        if (pos != text.length)
            throw error();
        return pairs;
    }

    private static bool isStop(char c, scope const char[] stops) @safe pure nothrow @nogc
    {
        foreach (s; stops)
            if (c == s)
                return true;
        return false;
    }

    /// A quoted string at the current position, unescaped.
    private string quoted() @safe
    {
        expect('\'');
        string s;
        for (;;)
        {
            const c = next();
            if (c == '\'')
            {
                if (pos < text.length && text[pos] == '\'')
                {
                    s ~= '\''; // a doubled quote, as in SQL
                    pos++;
                    continue;
                }
                return s;
            }
            if (c != '\\')
            {
                s ~= c;
                continue;
            }
            const e = next();
            switch (e)
            {
            case 'b':
                s ~= '\b';
                break;
            case 'f':
                s ~= '\f';
                break;
            case 'n':
                s ~= '\n';
                break;
            case 'r':
                s ~= '\r';
                break;
            case 't':
                s ~= '\t';
                break;
            case '0':
                s ~= '\0';
                break;
            case 'x':
                s ~= cast(char)(hexDigit(next()) * 16 + hexDigit(next()));
                break;
            default: // \' \\ and any other escaped character stand for themselves
                s ~= e;
            }
        }
    }

    /// The text of a nested list at the current position, brackets included.
    private string nested() @safe
    {
        const start = pos;
        size_t depth;
        bool inQuotes;
        while (pos < text.length)
        {
            const c = text[pos++];
            if (inQuotes)
            {
                if (c == '\\')
                    pos++;
                else if (c == '\'')
                    inQuotes = false;
            }
            else if (c == '\'')
                inQuotes = true;
            else if (c == '[' || c == '(' || c == '{')
                depth++;
            else if ((c == ']' || c == ')' || c == '}') && --depth == 0)
                return text[start .. pos];
        }
        throw error();
    }

    private ubyte hexDigit(char c) @safe
    {
        if (c >= '0' && c <= '9')
            return cast(ubyte)(c - '0');
        if (c >= 'a' && c <= 'f')
            return cast(ubyte)(c - 'a' + 10);
        if (c >= 'A' && c <= 'F')
            return cast(ubyte)(c - 'A' + 10);
        throw error();
    }

    private void skipSpaces() @safe pure nothrow
    {
        while (pos < text.length && (text[pos] == ' ' || text[pos] == '\t' || text[pos] == '\n'))
            pos++;
    }

    private char peek() @safe
    {
        if (pos >= text.length)
            throw error();
        return text[pos];
    }

    private char next() @safe
    {
        const c = peek();
        pos++;
        return c;
    }

    private void expect(char c) @safe
    {
        if (next() != c)
            throw error();
    }

    private ClientException error() const @safe
    {
        return new ClientException(
                "Cannot parse '" ~ text ~ "' as " ~ kind ~ " for column '" ~ target.name ~ "' ("
                ~ target.typeName ~ ")");
    }
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.types.string : StringColumn;

    auto target = new StringColumn("c");
    alias K = TextElement.Kind;
    const e = parseTextList(` ( 1, 'it''s', NULL, [2, (3, ']')], 'a\nb' ) `, '(', ')', target, "a tuple");
    assert(e == [
        TextElement(K.bare, "1"), TextElement(K.quoted, "it's"), TextElement(K.null_, "NULL"),
        TextElement(K.composite, "[2, (3, ']')]"), TextElement(K.quoted, "a\nb")
    ]);
    assert(parseTextList("[]", '[', ']', target, "an array").length == 0);
    foreach (bad; ["", "(", "(1,", "(1)x", "1", "(,)", "('a", "[1]"])
        assertThrown!ClientException(parseTextList(bad, '(', ')', target, "a tuple"), bad);
}

@safe unittest
{
    import std.exception : assertThrown;
    import clickhoused.types.string : StringColumn;

    auto target = new StringColumn("c");
    alias K = TextElement.Kind;
    const pairs = parseTextPairs(` { 'a' : 1, 2:'it''s', 'n':NULL, 'x':[1, 2], 'm':{'k':(1, 2)} } `, target);
    assert(pairs.length == 5);
    assert(pairs[0] == [TextElement(K.quoted, "a"), TextElement(K.bare, "1")]);
    assert(pairs[1] == [TextElement(K.bare, "2"), TextElement(K.quoted, "it's")]);
    assert(pairs[2][1].kind == K.null_ && pairs[3][1] == TextElement(K.composite, "[1, 2]"));
    assert(pairs[4][1] == TextElement(K.composite, "{'k':(1, 2)}"));
    assert(parseTextPairs("{}", target).length == 0);
    foreach (bad; [
        "", "{", "{'a'}", "{'a':}", "{:1}", "{'a':1,}", "{'a':1} x", "['a':1]", "{'a' 1}"
    ])
        assertThrown!ClientException(parseTextPairs(bad, target), bad);
}
