const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A parsed dotenv entry.
const Entry = struct {
    key: []const u8,
    value: []const u8,
};

/// Loads variables from a `.env` file in the current working directory into
/// `environ_map`. Existing variables are NOT overwritten (real environment
/// takes precedence). If the file does not exist, this is a silent no-op.
///
/// The parser is compatible with motdotla/dotenv v17.
pub fn loadInto(
    allocator: Allocator,
    environ_map: *std.process.Environ.Map,
    io: Io,
) !void {
    const content = Io.Dir.cwd().readFileAlloc(io, ".env", allocator, .limited(1024 * 1024)) catch return;
    defer allocator.free(content);

    const normalized = normalizeLineEndings(content);
    var it = Parser.init(normalized);
    while (it.next()) |entry| {
        if (!environ_map.contains(entry.key)) {
            try environ_map.put(entry.key, entry.value);
        }
    }
}

/// Replace `\r\n` with `\n` and standalone `\r` with `\n` in-place.
/// Returns the (possibly shorter) valid region of the buffer.
/// This matches the JS `src.replace(/\r\n?/mg, '\n')` preprocessing.
///
/// Must be called on the mutable buffer before passing to `Parser.init`.
pub fn normalizeLineEndings(buf: []u8) []const u8 {
    var read: usize = 0;
    var write: usize = 0;
    while (read < buf.len) {
        if (buf[read] == '\r') {
            buf[write] = '\n';
            write += 1;
            read += 1;
            // Skip `\n` after `\r` (CRLF → single LF)
            if (read < buf.len and buf[read] == '\n') read += 1;
        } else {
            buf[write] = buf[read];
            write += 1;
            read += 1;
        }
    }
    return buf[0..write];
}

/// Stateless, zero-allocation dotenv parser. Iterates over the entries in a
/// dotenv source buffer, returning slices into the original buffer (or into
/// static replacements for escape-expanded values).
///
/// For values that require escape expansion (double-quoted values containing
/// `\n` or `\r`), the expanded result is written into a small internal scratch
/// buffer. The returned slices are valid until the next call to `next()`.
pub const Parser = struct {
    src: []const u8,
    pos: usize,
    scratch: [4096]u8,
    scratch_len: usize,

    pub fn init(src: []const u8) Parser {
        return .{
            .src = src,
            .pos = 0,
            .scratch = undefined,
            .scratch_len = 0,
        };
    }

    pub fn next(self: *Parser) ?Entry {
        while (self.pos < self.src.len) {
            if (self.parseLine()) |entry| return entry;
        }
        return null;
    }

    /// Try to parse one line starting at `self.pos`. Advances `pos` past the
    /// consumed content. Returns `null` if the line is blank / comment /
    /// malformed (caller should retry with the next line).
    fn parseLine(self: *Parser) ?Entry {
        // Skip leading whitespace (including BOM U+FEFF encoded as UTF-8:
        // 0xEF 0xBB 0xBF — the byte 0xEF is not in ` \t\r\n` so BOM won't
        // be stripped by this loop, but that matches JS `\s` which does match
        // \uFEFF. We handle BOM explicitly.)
        self.skipSpaces();
        if (self.pos < self.src.len and self.atBom()) {
            self.pos += 3;
            self.skipSpaces();
        }

        // EOF or empty line?
        if (self.pos >= self.src.len) return null;
        if (self.peekByte() == '\n') {
            self.pos += 1;
            return null;
        }

        // Comment line?
        if (self.peekByte() == '#') {
            self.skipToNextLine();
            return null;
        }

        // Optional `export ` prefix
        if (self.remaining() >= 7 and std.mem.eql(u8, self.src[self.pos..][0..6], "export") and
            isHorizSpace(self.src[self.pos + 6]))
        {
            self.pos += 6;
            self.skipHorizSpaces();
        }

        // Key: [A-Za-z0-9_.-]+
        const key_start = self.pos;
        while (self.pos < self.src.len and isKeyChar(self.peekByte())) {
            self.pos += 1;
        }
        const key = self.src[key_start..self.pos];
        if (key.len == 0) {
            self.skipToNextLine();
            return null;
        }

        // Separator: `=` (with optional surrounding whitespace) or `: ` (colon + mandatory space)
        self.skipHorizSpaces();
        if (self.pos >= self.src.len) {
            // Key with no separator — skip
            return null;
        }

        const sep = self.peekByte();
        if (sep == '=') {
            self.pos += 1;
            self.skipHorizSpacesLazy();
        } else if (sep == ':') {
            // Colon requires at least one trailing whitespace
            if (self.pos + 1 >= self.src.len or !isHorizSpace(self.src[self.pos + 1])) {
                self.skipToNextLine();
                return null;
            }
            self.pos += 1;
            self.skipHorizSpaces();
        } else {
            // No valid separator
            self.skipToNextLine();
            return null;
        }

        // Value
        const value = self.parseValue();
        return .{ .key = key, .value = value };
    }

    fn parseValue(self: *Parser) []const u8 {
        if (self.pos >= self.src.len or self.peekByte() == '\n') {
            // Empty value
            self.advancePastNewline();
            return "";
        }

        const first = self.peekByte();
        if (first == '\'' or first == '"' or first == '`') {
            return self.parseQuotedValue(first);
        }
        return self.parseUnquotedValue();
    }

    fn parseQuotedValue(self: *Parser, quote: u8) []const u8 {
        const is_double = (quote == '"');
        self.pos += 1; // skip opening quote
        const val_start = self.pos;

        // Scan for closing quote, allowing `\<quote>` escapes
        while (self.pos < self.src.len) {
            const b = self.src[self.pos];
            if (b == '\\' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == quote) {
                self.pos += 2; // skip escaped quote
                continue;
            }
            if (b == quote) break;
            self.pos += 1;
        }

        const val_end = self.pos;
        const raw = self.src[val_start..val_end];

        // Skip closing quote if present
        if (self.pos < self.src.len and self.src[self.pos] == quote) {
            self.pos += 1;
        }

        // Skip trailing whitespace + optional inline comment + rest of line
        self.skipTrailingComment();

        if (is_double and (std.mem.indexOfScalar(u8, raw, '\\') != null)) {
            return self.expandDoubleQuoted(raw);
        }
        return raw;
    }

    fn parseUnquotedValue(self: *Parser) []const u8 {
        const val_start = self.pos;
        // Unquoted: everything up to `#`, `\r`, or `\n`
        while (self.pos < self.src.len) {
            const b = self.src[self.pos];
            if (b == '#' or b == '\r' or b == '\n') break;
            self.pos += 1;
        }
        const val_end = self.pos;

        // Skip inline comment if `#`
        self.skipTrailingComment();

        // Trim the raw value
        return std.mem.trim(u8, self.src[val_start..val_end], " \t");
    }

    /// Expand `\n` → LF and `\r` → CR in double-quoted values. Writes into
    /// the internal scratch buffer; returns a slice into it.
    fn expandDoubleQuoted(self: *Parser, raw: []const u8) []const u8 {
        self.scratch_len = 0;
        var i: usize = 0;
        while (i < raw.len) {
            if (raw[i] == '\\' and i + 1 < raw.len) {
                const nc = raw[i + 1];
                if (nc == 'n') {
                    self.scratchPut('\n');
                    i += 2;
                    continue;
                } else if (nc == 'r') {
                    self.scratchPut('\r');
                    i += 2;
                    continue;
                }
            }
            self.scratchPut(raw[i]);
            i += 1;
        }
        return self.scratch[0..self.scratch_len];
    }

    fn scratchPut(self: *Parser, b: u8) void {
        if (self.scratch_len < self.scratch.len) {
            self.scratch[self.scratch_len] = b;
            self.scratch_len += 1;
        }
    }

    // -- Helpers --

    fn peekByte(self: *const Parser) u8 {
        return self.src[self.pos];
    }

    fn remaining(self: *const Parser) usize {
        return self.src.len - self.pos;
    }

    fn atBom(self: *const Parser) bool {
        return self.remaining() >= 3 and
            self.src[self.pos] == 0xEF and
            self.src[self.pos + 1] == 0xBB and
            self.src[self.pos + 2] == 0xBF;
    }

    fn skipSpaces(self: *Parser) void {
        while (self.pos < self.src.len and isSpace(self.src[self.pos])) {
            self.pos += 1;
        }
    }

    fn skipHorizSpaces(self: *Parser) void {
        while (self.pos < self.src.len and isHorizSpace(self.src[self.pos])) {
            self.pos += 1;
        }
    }

    /// Lazy variant: skip at most zero horizontal spaces (used after `=` to
    /// match the JS regex `\s*?` which is lazy). In practice we still need to
    /// skip spaces before a quoted value's opening quote so that
    /// `FOO=  "bar"` works. We skip horizontal spaces here.
    fn skipHorizSpacesLazy(self: *Parser) void {
        self.skipHorizSpaces();
    }

    fn skipToNextLine(self: *Parser) void {
        while (self.pos < self.src.len and self.src[self.pos] != '\n') {
            self.pos += 1;
        }
        self.advancePastNewline();
    }

    fn skipTrailingComment(self: *Parser) void {
        // Skip the rest of the line (whitespace, `# comment`, etc.)
        while (self.pos < self.src.len and self.src[self.pos] != '\n') {
            self.pos += 1;
        }
        self.advancePastNewline();
    }

    fn advancePastNewline(self: *Parser) void {
        if (self.pos < self.src.len and self.src[self.pos] == '\n') {
            self.pos += 1;
        }
    }

    fn isKeyChar(c: u8) bool {
        return switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '_', '.', '-' => true,
            else => false,
        };
    }

    fn isHorizSpace(c: u8) bool {
        return c == ' ' or c == '\t';
    }

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or c == '\n';
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn collect(src: []const u8) std.StringHashMap([]const u8) {
    return collectSlice(src);
}

fn collectSlice(src: []const u8) std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(testing.allocator);
    var parser = Parser.init(src);
    while (parser.next()) |entry| {
        map.put(entry.key, entry.value) catch unreachable;
    }
    return map;
}

// -- Basic key=value --

test "basic key=value" {
    var m = collect("FOO=bar");
    defer m.deinit();
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

test "multiple lines" {
    var m = collect("A=1\nB=2\nC=3\n");
    defer m.deinit();
    try testing.expectEqualStrings("1", m.get("A").?);
    try testing.expectEqualStrings("2", m.get("B").?);
    try testing.expectEqualStrings("3", m.get("C").?);
}

// -- Comment handling --

test "comment lines" {
    var m = collect("# this is a comment\nFOO=bar\n# another\n");
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.count());
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

test "inline comment unquoted" {
    var m = collect("FOO=bar # comment");
    defer m.deinit();
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

test "hash in unquoted value truncates" {
    var m = collect("FOO=hello#world");
    defer m.deinit();
    try testing.expectEqualStrings("hello", m.get("FOO").?);
}

test "hash immediately after equals" {
    var m = collect("FOO=#bar");
    defer m.deinit();
    try testing.expectEqualStrings("", m.get("FOO").?);
}

// -- Quoting: single quotes --

test "single quoted value" {
    var m = collect("FOO='hello world'");
    defer m.deinit();
    try testing.expectEqualStrings("hello world", m.get("FOO").?);
}

test "single quotes preserve backslash-n literally" {
    var m = collect("FOO='hello\\nworld'");
    defer m.deinit();
    try testing.expectEqualStrings("hello\\nworld", m.get("FOO").?);
}

test "single quotes preserve internal spaces" {
    var m = collect("FOO='  spaced  '");
    defer m.deinit();
    try testing.expectEqualStrings("  spaced  ", m.get("FOO").?);
}

test "single quotes with hash inside" {
    var m = collect("FOO='hash#here'");
    defer m.deinit();
    try testing.expectEqualStrings("hash#here", m.get("FOO").?);
}

// -- Quoting: double quotes --

test "double quoted value" {
    var m = collect("FOO=\"hello world\"");
    defer m.deinit();
    try testing.expectEqualStrings("hello world", m.get("FOO").?);
}

test "double quotes expand backslash-n" {
    var m = collect("FOO=\"hello\\nworld\"");
    defer m.deinit();
    try testing.expectEqualStrings("hello\nworld", m.get("FOO").?);
}

test "double quotes expand backslash-r" {
    var m = collect("FOO=\"hello\\rworld\"");
    defer m.deinit();
    try testing.expectEqualStrings("hello\rworld", m.get("FOO").?);
}

test "double quotes do not expand backslash-t" {
    var m = collect("FOO=\"hello\\tworld\"");
    defer m.deinit();
    try testing.expectEqualStrings("hello\\tworld", m.get("FOO").?);
}

test "double quotes do not expand backslash-backslash" {
    var m = collect("FOO=\"a\\\\b\"");
    defer m.deinit();
    try testing.expectEqualStrings("a\\\\b", m.get("FOO").?);
}

test "double quotes with hash inside" {
    var m = collect("FOO=\"hash#here\" # comment");
    defer m.deinit();
    try testing.expectEqualStrings("hash#here", m.get("FOO").?);
}

// -- Quoting: backtick --

test "backtick quoted value" {
    var m = collect("FOO=`hello world`");
    defer m.deinit();
    try testing.expectEqualStrings("hello world", m.get("FOO").?);
}

test "backtick preserves backslash-n literally" {
    var m = collect("FOO=`hello\\nworld`");
    defer m.deinit();
    try testing.expectEqualStrings("hello\\nworld", m.get("FOO").?);
}

// -- Multiline values --

test "double quoted multiline" {
    var m = collect("FOO=\"line1\nline2\nline3\"");
    defer m.deinit();
    try testing.expectEqualStrings("line1\nline2\nline3", m.get("FOO").?);
}

test "single quoted multiline" {
    var m = collect("FOO='line1\nline2'");
    defer m.deinit();
    try testing.expectEqualStrings("line1\nline2", m.get("FOO").?);
}

test "backtick multiline" {
    var m = collect("FOO=`line1\nline2`");
    defer m.deinit();
    try testing.expectEqualStrings("line1\nline2", m.get("FOO").?);
}

test "value after multiline" {
    var m = collect("A=\"multi\nline\"\nB=after");
    defer m.deinit();
    try testing.expectEqualStrings("multi\nline", m.get("A").?);
    try testing.expectEqualStrings("after", m.get("B").?);
}

// -- Whitespace handling --

test "leading whitespace on line" {
    var m = collect("  FOO=bar");
    defer m.deinit();
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

test "whitespace around equals" {
    var m = collect("FOO = bar");
    defer m.deinit();
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

test "trailing whitespace trimmed for unquoted" {
    var m = collect("FOO=bar   ");
    defer m.deinit();
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

test "quoted value preserves internal whitespace" {
    var m = collect("FOO=\"  bar  \"");
    defer m.deinit();
    try testing.expectEqualStrings("  bar  ", m.get("FOO").?);
}

test "whitespace before quoted value" {
    var m = collect("FOO=  \"bar\"");
    defer m.deinit();
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

test "blank lines skipped" {
    var m = collect("A=1\n\n\nB=2\n");
    defer m.deinit();
    try testing.expectEqual(@as(usize, 2), m.count());
}

// -- Empty values --

test "empty value: key equals nothing" {
    var m = collect("FOO=");
    defer m.deinit();
    try testing.expectEqualStrings("", m.get("FOO").?);
}

test "empty value: key equals spaces" {
    var m = collect("FOO=   ");
    defer m.deinit();
    try testing.expectEqualStrings("", m.get("FOO").?);
}

test "empty single quotes" {
    var m = collect("FOO=''");
    defer m.deinit();
    try testing.expectEqualStrings("", m.get("FOO").?);
}

test "empty double quotes" {
    var m = collect("FOO=\"\"");
    defer m.deinit();
    try testing.expectEqualStrings("", m.get("FOO").?);
}

// -- export prefix --

test "export prefix" {
    var m = collect("export FOO=bar");
    defer m.deinit();
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

test "export with multiple spaces" {
    var m = collect("export   FOO=bar");
    defer m.deinit();
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

// -- Colon separator --

test "colon separator with space" {
    var m = collect("FOO: bar");
    defer m.deinit();
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

test "colon without space is skipped" {
    var m = collect("FOO:bar\nBAR=ok");
    defer m.deinit();
    try testing.expect(m.get("FOO") == null);
    try testing.expectEqualStrings("ok", m.get("BAR").?);
}

// -- Key charset --

test "key with dots and dashes" {
    var m = collect("my.app-key=val");
    defer m.deinit();
    try testing.expectEqualStrings("val", m.get("my.app-key").?);
}

test "key starting with digit" {
    var m = collect("123=val");
    defer m.deinit();
    try testing.expectEqualStrings("val", m.get("123").?);
}

test "key with invalid chars skipped" {
    var m = collect("a b=1\nGOOD=2");
    defer m.deinit();
    try testing.expect(m.get("a b") == null);
    try testing.expectEqualStrings("2", m.get("GOOD").?);
}

// -- Duplicate keys --

test "duplicate keys: last wins" {
    var m = collect("DUP=one\nDUP=two");
    defer m.deinit();
    try testing.expectEqualStrings("two", m.get("DUP").?);
}

// -- Malformed lines --

test "no separator skipped" {
    var m = collect("NOSEP\nGOOD=val");
    defer m.deinit();
    try testing.expect(m.get("NOSEP") == null);
    try testing.expectEqualStrings("val", m.get("GOOD").?);
}

test "equals with no key skipped" {
    var m = collect("=value\nGOOD=val");
    defer m.deinit();
    try testing.expectEqual(@as(usize, 1), m.count());
}

// -- Escaped quotes inside quoted values --

test "escaped single quote inside single quotes" {
    var m = collect("FOO='it\\'s here'");
    defer m.deinit();
    try testing.expectEqualStrings("it\\'s here", m.get("FOO").?);
}

test "escaped double quote inside double quotes" {
    var m = collect("FOO=\"say\\\"hi\"");
    defer m.deinit();
    try testing.expectEqualStrings("say\\\"hi", m.get("FOO").?);
}

// -- CRLF handling --

test "crlf line endings" {
    var buf = "A=1\r\nB=2\r\n".*;
    const normalized = normalizeLineEndings(&buf);
    var m = collectSlice(normalized);
    defer m.deinit();
    try testing.expectEqualStrings("1", m.get("A").?);
    try testing.expectEqualStrings("2", m.get("B").?);
}

test "standalone cr line endings" {
    var buf = "A=1\rB=2\r".*;
    const normalized = normalizeLineEndings(&buf);
    var m = collectSlice(normalized);
    defer m.deinit();
    try testing.expectEqualStrings("1", m.get("A").?);
    try testing.expectEqualStrings("2", m.get("B").?);
}

// -- BOM handling --

test "utf8 bom at start of file" {
    var m = collect("\xEF\xBB\xBFFOO=bar");
    defer m.deinit();
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

// -- No trailing newline --

test "file without trailing newline" {
    var m = collect("FOO=bar");
    defer m.deinit();
    try testing.expectEqualStrings("bar", m.get("FOO").?);
}

// -- Mixed scenario --

test "complex mixed scenario" {
    const src =
        \\# Database config
        \\DB_HOST=localhost
        \\DB_PORT=5432
        \\DB_NAME="my_database"
        \\
        \\# API Keys
        \\export API_KEY='sk-1234567890'
        \\SECRET="multi
        \\line
        \\value"
        \\EMPTY=
        \\SPACED=  hello world  
        \\
    ;
    var m = collect(src);
    defer m.deinit();
    try testing.expectEqualStrings("localhost", m.get("DB_HOST").?);
    try testing.expectEqualStrings("5432", m.get("DB_PORT").?);
    try testing.expectEqualStrings("my_database", m.get("DB_NAME").?);
    try testing.expectEqualStrings("sk-1234567890", m.get("API_KEY").?);
    try testing.expectEqualStrings("multi\nline\nvalue", m.get("SECRET").?);
    try testing.expectEqualStrings("", m.get("EMPTY").?);
    try testing.expectEqualStrings("hello world", m.get("SPACED").?);
}

// -- backslash-backslash-n in double quotes --

test "double backslash then n in double quotes" {
    // `\\n` is three chars: `\`, `\`, `n`. The JS replace(/\\n/g, '\n')
    // sees `\n` starting at index 1, so result is `\` + LF.
    var m = collect("FOO=\"a\\\\nb\"");
    defer m.deinit();
    try testing.expectEqualStrings("a\\\nb", m.get("FOO").?);
}

// =============================================================================
// Official motdotla/dotenv test-parse.js fixture
// =============================================================================

test "official fixture: tests/.env" {
    const src =
        \\BASIC=basic
        \\
        \\# previous line intentionally left blank
        \\AFTER_LINE=after_line
        \\EMPTY=
        \\EMPTY_SINGLE_QUOTES=''
        \\EMPTY_DOUBLE_QUOTES=""
        \\EMPTY_BACKTICKS=``
        \\SINGLE_QUOTES='single_quotes'
        \\SINGLE_QUOTES_SPACED='    single quotes    '
        \\DOUBLE_QUOTES="double_quotes"
        \\DOUBLE_QUOTES_SPACED="    double quotes    "
        \\DOUBLE_QUOTES_INSIDE_SINGLE='double "quotes" work inside single quotes'
        \\DOUBLE_QUOTES_WITH_NO_SPACE_BRACKET="{ port: $MONGOLAB_PORT}"
        \\SINGLE_QUOTES_INSIDE_DOUBLE="single 'quotes' work inside double quotes"
        \\BACKTICKS_INSIDE_SINGLE='`backticks` work inside single quotes'
        \\BACKTICKS_INSIDE_DOUBLE="`backticks` work inside double quotes"
        \\BACKTICKS=`backticks`
        \\BACKTICKS_SPACED=`    backticks    `
        \\DOUBLE_QUOTES_INSIDE_BACKTICKS=`double "quotes" work inside backticks`
        \\SINGLE_QUOTES_INSIDE_BACKTICKS=`single 'quotes' work inside backticks`
        \\DOUBLE_AND_SINGLE_QUOTES_INSIDE_BACKTICKS=`double "quotes" and single 'quotes' work inside backticks`
        \\EXPAND_NEWLINES="expand\nnew\nlines"
        \\DONT_EXPAND_UNQUOTED=dontexpand\nnewlines
        \\DONT_EXPAND_SQUOTED='dontexpand\nnewlines'
        \\# COMMENTS=work
        \\INLINE_COMMENTS=inline comments # work #very #well
        \\INLINE_COMMENTS_SINGLE_QUOTES='inline comments outside of #singlequotes' # work
        \\INLINE_COMMENTS_DOUBLE_QUOTES="inline comments outside of #doublequotes" # work
        \\INLINE_COMMENTS_BACKTICKS=`inline comments outside of #backticks` # work
        \\INLINE_COMMENTS_SPACE=inline comments start with a#number sign. no space required.
        \\EQUAL_SIGNS=equals==
        \\RETAIN_INNER_QUOTES={"foo": "bar"}
        \\RETAIN_INNER_QUOTES_AS_STRING='{"foo": "bar"}'
        \\RETAIN_INNER_QUOTES_AS_BACKTICKS=`{"foo": "bar's"}`
        \\TRIM_SPACE_FROM_UNQUOTED=    some spaced out string
        \\USERNAME=therealnerdybeast@example.tld
        \\    SPACED_KEY = parsed
    ;
    var m = collect(src);
    defer m.deinit();

    try testing.expectEqualStrings("basic", m.get("BASIC").?);
    try testing.expectEqualStrings("after_line", m.get("AFTER_LINE").?);
    try testing.expectEqualStrings("", m.get("EMPTY").?);
    try testing.expectEqualStrings("", m.get("EMPTY_SINGLE_QUOTES").?);
    try testing.expectEqualStrings("", m.get("EMPTY_DOUBLE_QUOTES").?);
    try testing.expectEqualStrings("", m.get("EMPTY_BACKTICKS").?);
    try testing.expectEqualStrings("single_quotes", m.get("SINGLE_QUOTES").?);
    try testing.expectEqualStrings("    single quotes    ", m.get("SINGLE_QUOTES_SPACED").?);
    try testing.expectEqualStrings("double_quotes", m.get("DOUBLE_QUOTES").?);
    try testing.expectEqualStrings("    double quotes    ", m.get("DOUBLE_QUOTES_SPACED").?);
    try testing.expectEqualStrings("double \"quotes\" work inside single quotes", m.get("DOUBLE_QUOTES_INSIDE_SINGLE").?);
    try testing.expectEqualStrings("{ port: $MONGOLAB_PORT}", m.get("DOUBLE_QUOTES_WITH_NO_SPACE_BRACKET").?);
    try testing.expectEqualStrings("single 'quotes' work inside double quotes", m.get("SINGLE_QUOTES_INSIDE_DOUBLE").?);
    try testing.expectEqualStrings("`backticks` work inside single quotes", m.get("BACKTICKS_INSIDE_SINGLE").?);
    try testing.expectEqualStrings("`backticks` work inside double quotes", m.get("BACKTICKS_INSIDE_DOUBLE").?);
    try testing.expectEqualStrings("backticks", m.get("BACKTICKS").?);
    try testing.expectEqualStrings("    backticks    ", m.get("BACKTICKS_SPACED").?);
    try testing.expectEqualStrings("double \"quotes\" work inside backticks", m.get("DOUBLE_QUOTES_INSIDE_BACKTICKS").?);
    try testing.expectEqualStrings("single 'quotes' work inside backticks", m.get("SINGLE_QUOTES_INSIDE_BACKTICKS").?);
    try testing.expectEqualStrings("double \"quotes\" and single 'quotes' work inside backticks", m.get("DOUBLE_AND_SINGLE_QUOTES_INSIDE_BACKTICKS").?);
    try testing.expectEqualStrings("expand\nnew\nlines", m.get("EXPAND_NEWLINES").?);
    try testing.expectEqualStrings("dontexpand\\nnewlines", m.get("DONT_EXPAND_UNQUOTED").?);
    try testing.expectEqualStrings("dontexpand\\nnewlines", m.get("DONT_EXPAND_SQUOTED").?);
    try testing.expect(m.get("COMMENTS") == null);
    try testing.expectEqualStrings("inline comments", m.get("INLINE_COMMENTS").?);
    try testing.expectEqualStrings("inline comments outside of #singlequotes", m.get("INLINE_COMMENTS_SINGLE_QUOTES").?);
    try testing.expectEqualStrings("inline comments outside of #doublequotes", m.get("INLINE_COMMENTS_DOUBLE_QUOTES").?);
    try testing.expectEqualStrings("inline comments outside of #backticks", m.get("INLINE_COMMENTS_BACKTICKS").?);
    try testing.expectEqualStrings("inline comments start with a", m.get("INLINE_COMMENTS_SPACE").?);
    try testing.expectEqualStrings("equals==", m.get("EQUAL_SIGNS").?);
    try testing.expectEqualStrings("{\"foo\": \"bar\"}", m.get("RETAIN_INNER_QUOTES").?);
    try testing.expectEqualStrings("{\"foo\": \"bar\"}", m.get("RETAIN_INNER_QUOTES_AS_STRING").?);
    try testing.expectEqualStrings("{\"foo\": \"bar's\"}", m.get("RETAIN_INNER_QUOTES_AS_BACKTICKS").?);
    try testing.expectEqualStrings("some spaced out string", m.get("TRIM_SPACE_FROM_UNQUOTED").?);
    try testing.expectEqualStrings("therealnerdybeast@example.tld", m.get("USERNAME").?);
    try testing.expectEqualStrings("parsed", m.get("SPACED_KEY").?);
}

// =============================================================================
// Official motdotla/dotenv test-parse-multiline.js fixture
// =============================================================================

test "official fixture: multiline" {
    const src =
        \\BASIC=basic
        \\
        \\# previous line intentionally left blank
        \\AFTER_LINE=after_line
        \\EMPTY=
        \\SINGLE_QUOTES='single_quotes'
        \\SINGLE_QUOTES_SPACED='    single quotes    '
        \\DOUBLE_QUOTES="double_quotes"
        \\DOUBLE_QUOTES_SPACED="    double quotes    "
        \\EXPAND_NEWLINES="expand\nnew\nlines"
        \\DONT_EXPAND_UNQUOTED=dontexpand\nnewlines
        \\DONT_EXPAND_SQUOTED='dontexpand\nnewlines'
        \\# COMMENTS=work
        \\EQUAL_SIGNS=equals==
        \\RETAIN_INNER_QUOTES={"foo": "bar"}
        \\
        \\RETAIN_INNER_QUOTES_AS_STRING='{"foo": "bar"}'
        \\TRIM_SPACE_FROM_UNQUOTED=    some spaced out string
        \\USERNAME=therealnerdybeast@example.tld
        \\    SPACED_KEY = parsed
        \\
        \\MULTI_DOUBLE_QUOTED="THIS
        \\IS
        \\A
        \\MULTILINE
        \\STRING"
        \\
        \\MULTI_SINGLE_QUOTED='THIS
        \\IS
        \\A
        \\MULTILINE
        \\STRING'
        \\
        \\MULTI_BACKTICKED=`THIS
        \\IS
        \\A
        \\"MULTILINE'S"
        \\STRING`
    ;
    var m = collect(src);
    defer m.deinit();

    try testing.expectEqualStrings("basic", m.get("BASIC").?);
    try testing.expectEqualStrings("after_line", m.get("AFTER_LINE").?);
    try testing.expectEqualStrings("", m.get("EMPTY").?);
    try testing.expectEqualStrings("single_quotes", m.get("SINGLE_QUOTES").?);
    try testing.expectEqualStrings("    single quotes    ", m.get("SINGLE_QUOTES_SPACED").?);
    try testing.expectEqualStrings("double_quotes", m.get("DOUBLE_QUOTES").?);
    try testing.expectEqualStrings("    double quotes    ", m.get("DOUBLE_QUOTES_SPACED").?);
    try testing.expectEqualStrings("expand\nnew\nlines", m.get("EXPAND_NEWLINES").?);
    try testing.expectEqualStrings("dontexpand\\nnewlines", m.get("DONT_EXPAND_UNQUOTED").?);
    try testing.expectEqualStrings("dontexpand\\nnewlines", m.get("DONT_EXPAND_SQUOTED").?);
    try testing.expect(m.get("COMMENTS") == null);
    try testing.expectEqualStrings("equals==", m.get("EQUAL_SIGNS").?);
    try testing.expectEqualStrings("{\"foo\": \"bar\"}", m.get("RETAIN_INNER_QUOTES").?);
    try testing.expectEqualStrings("{\"foo\": \"bar\"}", m.get("RETAIN_INNER_QUOTES_AS_STRING").?);
    try testing.expectEqualStrings("some spaced out string", m.get("TRIM_SPACE_FROM_UNQUOTED").?);
    try testing.expectEqualStrings("therealnerdybeast@example.tld", m.get("USERNAME").?);
    try testing.expectEqualStrings("parsed", m.get("SPACED_KEY").?);
    try testing.expectEqualStrings("THIS\nIS\nA\nMULTILINE\nSTRING", m.get("MULTI_DOUBLE_QUOTED").?);
    try testing.expectEqualStrings("THIS\nIS\nA\nMULTILINE\nSTRING", m.get("MULTI_SINGLE_QUOTED").?);
    try testing.expectEqualStrings("THIS\nIS\nA\n\"MULTILINE'S\"\nSTRING", m.get("MULTI_BACKTICKED").?);
}
