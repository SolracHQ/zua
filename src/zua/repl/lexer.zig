//! Tiny Lua lexer for lightweight syntax highlighting.
//!
//! This module tokenizes Lua source directly rather than depending on Lua's
//! internal lexer machinery.
const std = @import("std");

/// Errors surfaced by the lexer.
pub const Error = error{
    OutOfMemory,
};

/// Lua source token kinds produced by the lexer.
///
/// These are intended for syntax highlighting and simple classification.
pub const TokenKind = enum {
    keyword, // control keywords such as if, then, while, do, end, function, local, return
    keyword_value, // literal keywords such as true, false, nil
    builtin, // standard globals and library names such as print, ipairs, math, string
    custom, // user-defined identifiers detected by a custom lexer hook
    name,
    string,
    integer,
    number,
    symbol,
    comment,
    eos,
};

/// Optional hook to classify identifiers that are not builtins or keywords.
///
/// The lexer invokes this hook with the identifier text and returns `true`
/// for identifiers that should be classified as `.custom`.
pub const IdentifierHook = ?*const fn ([]const u8) bool;

/// A single token produced by the Lua lexer.
///
/// `offset` and `len` identify the token span in the original source.
pub const Token = struct {
    kind: TokenKind,
    offset: usize,
    len: usize,
};

/// Tokenizes Lua source into a list of lexer tokens.
///
/// This lexer is independent from Lua's internal parser and is designed for
/// lightweight syntax highlighting and simple source analysis.
///
/// Arguments:
/// - allocator: Allocator used for the returned token list.
/// - source: The Lua source to tokenize.
///
/// Returns:
/// - Error!std.ArrayList(Token): A token list ending with `.eos` on success.
pub fn lex(allocator: std.mem.Allocator, source: []const u8) Error!std.ArrayList(Token) {
    return lexWithHook(allocator, source, null);
}

pub fn lexWithHook(allocator: std.mem.Allocator, source: []const u8, custom_identifier_hook: IdentifierHook) Error!std.ArrayList(Token) {
    var tokens = std.ArrayList(Token).empty;
    var ok = false;
    defer if (!ok) tokens.deinit(allocator);

    var lexer = Lexer{
        .allocator = allocator,
        .source = source,
        .pos = 0,
        .custom_identifier_hook = custom_identifier_hook,
    };

    try lexer.lexAll(&tokens);

    ok = true;
    return tokens;
}

const Lexer = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize,
    custom_identifier_hook: IdentifierHook,

    /// Reads all tokens from the source and appends them to `tokens`.
    ///
    /// This stops once the source is consumed and always appends a trailing
    /// `.eos` token to mark the end of input.
    pub fn lexAll(self: *Lexer, tokens: *std.ArrayList(Token)) Error!void {
        while (self.pos < self.source.len) {
            const start = self.pos;
            const c = self.source[self.pos];

            if (isWhitespace(c)) {
                self.pos += 1;
                continue;
            }

            if (c == '-' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '-') {
                try self.lexComment(tokens, start);
                continue;
            }

            if (c == '"' or c == '\'') {
                try self.lexQuotedString(tokens, start, c);
                continue;
            }

            if (c == '[') {
                if (try self.tryLexLongBracketString(tokens, start)) continue;
                try tokens.append(self.allocator, Token{ .kind = .symbol, .offset = start, .len = 1 });
                self.pos += 1;
                continue;
            }

            if (isDigit(c) or (c == '.' and self.pos + 1 < self.source.len and isDigit(self.source[self.pos + 1]))) {
                try self.lexNumber(tokens, start);
                continue;
            }

            if (isIdentifierStart(c)) {
                try self.lexIdentifier(tokens, start);
                continue;
            }

            if (c == '.' and self.pos + 1 < self.source.len) {
                if (self.source[self.pos + 1] == '.' and self.pos + 2 < self.source.len and self.source[self.pos + 2] == '.') {
                    try tokens.append(self.allocator, Token{ .kind = .symbol, .offset = start, .len = 3 });
                    self.pos += 3;
                    continue;
                }
                if (self.source[self.pos + 1] == '.') {
                    try tokens.append(self.allocator, Token{ .kind = .symbol, .offset = start, .len = 2 });
                    self.pos += 2;
                    continue;
                }
            }

            if (self.pos + 1 < self.source.len) {
                const two = self.source[self.pos .. self.pos + 2];
                if (std.mem.eql(u8, two, "==") or std.mem.eql(u8, two, "~=") or std.mem.eql(u8, two, "<=") or std.mem.eql(u8, two, ">=") or std.mem.eql(u8, two, "..")) {
                    try tokens.append(self.allocator, Token{ .kind = .symbol, .offset = start, .len = 2 });
                    self.pos += 2;
                    continue;
                }
            }

            try tokens.append(self.allocator, Token{ .kind = .symbol, .offset = start, .len = 1 });
            self.pos += 1;
        }

        try tokens.append(self.allocator, Token{ .kind = .eos, .offset = self.source.len, .len = 0 });
    }

    /// Lexes a Lua comment token starting at `start`.
    ///
    /// Handles both short comments and long-bracket comments.
    fn lexComment(self: *Lexer, tokens: *std.ArrayList(Token), start: usize) Error!void {
        self.pos += 2;
        if (self.pos < self.source.len and self.source[self.pos] == '[') {
            const matched = try self.tryLexLongBracket(tokens, start, .comment);
            if (matched) return;
        }

        while (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '\r') {
            self.pos += 1;
        }
        try tokens.append(self.allocator, Token{ .kind = .comment, .offset = start, .len = self.pos - start });
    }

    /// Attempts to lex a Lua long-bracket string literal starting at `start`.
    ///
    /// Returns `true` when the source matches a long-bracket string pattern.
    fn tryLexLongBracketString(self: *Lexer, tokens: *std.ArrayList(Token), start: usize) Error!bool {
        const matched = try self.tryLexLongBracket(tokens, start, .string);
        if (matched) return true;
        return false;
    }

    /// Attempts to lex a long-bracket string or comment starting at `start`.
    ///
    /// `kind` is either `.string` or `.comment` depending on the opening marker.
    fn tryLexLongBracket(self: *Lexer, tokens: *std.ArrayList(Token), start: usize, kind: TokenKind) Error!bool {
        const eq_count = self.longBracketLevel(start);
        if (eq_count == null) return false;

        const open_len = 2 + eq_count.?;
        self.pos = start + open_len;
        while (self.pos < self.source.len) {
            if (self.source[self.pos] == ']') {
                var p = self.pos + 1;
                while (p < self.source.len and self.source[p] == '=') : (p += 1) {}
                if (p < self.source.len and self.source[p] == ']' and p - (self.pos + 1) == eq_count) {
                    self.pos = p + 1;
                    try tokens.append(self.allocator, Token{ .kind = kind, .offset = start, .len = self.pos - start });
                    return true;
                }
            }
            self.pos += 1;
        }

        self.skipUntilBoundary();
        try tokens.append(self.allocator, Token{ .kind = kind, .offset = start, .len = self.pos - start });
        return true;
    }

    /// Lexes a quoted string literal starting at `start`.
    ///
    /// This handles both single-quoted and double-quoted strings.
    fn lexQuotedString(self: *Lexer, tokens: *std.ArrayList(Token), start: usize, quote: u8) Error!void {
        self.pos += 1;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\\') {
                self.pos += 2;
                continue;
            }
            if (c == quote) {
                self.pos += 1;
                try tokens.append(self.allocator, Token{ .kind = .string, .offset = start, .len = self.pos - start });
                return;
            }
            self.pos += 1;
        }
        self.skipUntilBoundary();
        try tokens.append(self.allocator, Token{ .kind = .string, .offset = start, .len = self.pos - start });
    }

    /// Lexes an identifier or keyword token starting at `start`.
    ///
    /// This classifier distinguishes keywords, literal keyword values, builtins,
    /// custom identifiers, and plain names.
    fn lexIdentifier(self: *Lexer, tokens: *std.ArrayList(Token), start: usize) Error!void {
        self.pos += 1;
        while (self.pos < self.source.len and isIdentifierContinue(self.source[self.pos])) {
            self.pos += 1;
        }
        const slice = self.source[start..self.pos];
        const kind = if (isKeywordValue(slice)) TokenKind.keyword_value else if (isKeyword(slice)) TokenKind.keyword else if (isBuiltin(slice)) TokenKind.builtin else if (self.custom_identifier_hook) |hook| (if (hook(slice)) TokenKind.custom else TokenKind.name) else TokenKind.name;
        try tokens.append(self.allocator, Token{ .kind = kind, .offset = start, .len = self.pos - start });
    }

    /// Lexes a numeric literal starting at `start`.
    ///
    /// Supports decimal, hexadecimal, and scientific notation forms.
    fn lexNumber(self: *Lexer, tokens: *std.ArrayList(Token), start: usize) Error!void {
        var has_dot = false;
        if (self.source[self.pos] == '0' and self.pos + 1 < self.source.len and (self.source[self.pos + 1] == 'x' or self.source[self.pos + 1] == 'X')) {
            self.pos += 2;
            while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) {
                self.pos += 1;
            }
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                has_dot = true;
                self.pos += 1;
                while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) {
                    self.pos += 1;
                }
            }
            if (self.pos < self.source.len and (self.source[self.pos] == 'p' or self.source[self.pos] == 'P')) {
                self.pos += 1;
                if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                    self.pos += 1;
                }
                if (self.pos >= self.source.len or !isDigit(self.source[self.pos])) {
                    self.skipUntilBoundary();
                    try tokens.append(self.allocator, Token{ .kind = if (has_dot) .number else .integer, .offset = start, .len = self.pos - start });
                    return;
                }
                while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                    self.pos += 1;
                }
            }
            try tokens.append(self.allocator, Token{ .kind = if (has_dot) .number else .integer, .offset = start, .len = self.pos - start });
            return;
        }

        if (self.source[self.pos] == '.') {
            self.pos += 1;
            has_dot = true;
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                self.pos += 1;
            }
        } else {
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                self.pos += 1;
            }
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                has_dot = true;
                self.pos += 1;
                while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                    self.pos += 1;
                }
            }
        }

        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.pos += 1;
            }
            if (self.pos >= self.source.len or !isDigit(self.source[self.pos])) {
                self.skipUntilBoundary();
                try tokens.append(self.allocator, Token{ .kind = if (has_dot) .number else .integer, .offset = start, .len = self.pos - start });
                return;
            }
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                self.pos += 1;
            }
            has_dot = true;
        }

        try tokens.append(self.allocator, Token{ .kind = if (has_dot) .number else .integer, .offset = start, .len = self.pos - start });
    }

    fn longBracketLevel(self: *Lexer, start: usize) ?usize {
        if (start + 1 >= self.source.len or self.source[start] != '[') return null;
        var p = start + 1;
        while (p < self.source.len and self.source[p] == '=') : (p += 1) {}
        if (p < self.source.len and self.source[p] == '[') {
            return p - (start + 1);
        }
        return null;
    }

    /// Advances to the next token boundary when a string or long-bracket literal
    /// is unterminated.
    ///
    /// This is used to recover from unterminated strings or long bracket blocks.
    fn skipUntilBoundary(self: *Lexer) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\n' or c == '\r' or c == ',' or c == ';' or c == '(' or c == ')' or c == '[' or c == ']' or c == '{' or c == '}' or c == '+' or c == '*' or c == '/' or c == '%' or c == '^' or c == '#' or c == '=' or c == '<' or c == '>' or c == ':' or c == '.') {
                break;
            }
            if (c == '-' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '-') {
                break;
            }
            self.pos += 1;
        }
    }
};

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\x0b' or c == '\x0c';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isIdentifierStart(c: u8) bool {
    return c == '_' or isAlpha(c);
}

fn isIdentifierContinue(c: u8) bool {
    return c == '_' or isAlpha(c) or isDigit(c);
}

fn isKeywordValue(slice: []const u8) bool {
    const values = [_][]const u8{ "true", "false", "nil" };
    for (values) |kw| {
        if (kw.len == slice.len and std.mem.eql(u8, kw, slice)) return true;
    }
    return false;
}

fn isKeyword(slice: []const u8) bool {
    const keywords = [_][]const u8{
        "and",      "break",  "do",   "else",  "elseif", "end", "for",
        "function", "goto",   "if",   "in",    "local",  "not", "or",
        "repeat",   "return", "then", "until", "while",
    };
    for (keywords) |kw| {
        if (kw.len == slice.len and std.mem.eql(u8, kw, slice)) return true;
    }
    return false;
}

fn isBuiltin(slice: []const u8) bool {
    const builtins = [_][]const u8{
        "assert",   "collectgarbage", "dofile",    "error",  "getmetatable", "ipairs",   "load",
        "loadfile", "loadstring",     "next",      "pairs",  "pcall",        "print",    "rawequal",
        "rawget",   "rawlen",         "rawset",    "select", "setmetatable", "tonumber", "tostring",
        "type",     "xpcall",         "coroutine", "debug",  "io",           "math",     "os",
        "package",  "string",         "table",     "utf8",
    };
    for (builtins) |kw| {
        if (kw.len == slice.len and std.mem.eql(u8, kw, slice)) return true;
    }
    return false;
}

test "lex basic lua source" {
    const source = "local x = true -- comment\nprint(\"hi\")";
    var tokens = lex(std.testing.allocator, source) catch unreachable;
    defer tokens.deinit(std.testing.allocator);

    const expected = &[_]Token{
        .{ .kind = .keyword, .offset = 0, .len = 5 },
        .{ .kind = .name, .offset = 6, .len = 1 },
        .{ .kind = .symbol, .offset = 8, .len = 1 },
        .{ .kind = .keyword_value, .offset = 10, .len = 4 },
        .{ .kind = .comment, .offset = 15, .len = 10 },
        .{ .kind = .builtin, .offset = 26, .len = 5 },
        .{ .kind = .symbol, .offset = 31, .len = 1 },
        .{ .kind = .string, .offset = 32, .len = 4 },
        .{ .kind = .symbol, .offset = 36, .len = 1 },
        .{ .kind = .eos, .offset = source.len, .len = 0 },
    };

    try std.testing.expect(tokens.items.len == expected.len);
    for (expected, 0..) |exp, i| {
        const tok = tokens.items[i];
        try std.testing.expect(tok.kind == exp.kind);
        try std.testing.expect(tok.offset == exp.offset);
        try std.testing.expect(tok.len == exp.len);
    }
}
