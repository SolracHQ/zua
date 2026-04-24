//! ANSI syntax highlighting helpers for the embedded REPL.
//!
//! This module maps lexer token kinds to color and style sequences and
//! renders highlighted source text for the current REPL line.
const std = @import("std");
const lexer = @import("lexer.zig");

/// Token kinds exposed to the REPL color hook.
pub const TokenKind = enum {
    keyword,
    keyword_value,
    builtin,
    name,
    string,
    integer,
    number,
    symbol,
    comment,
};

/// ANSI color variants used by the REPL syntax highlighter.
///
/// This type is returned by custom identifier hooks and is used by the
/// highlight renderer to produce the proper escape sequence for the current
/// terminal.
pub const Color = union(enum) {
    none,
    ansi: u8,
    ansi256: u8,
    rgb: struct { r: u8, g: u8, b: u8 },

    pub fn render(self: Color, buf: []u8) []const u8 {
        return switch (self) {
            .none => buf[0..0],
            .ansi => |n| std.fmt.bufPrint(buf, "\x1b[{d}m", .{n}) catch buf[0..0],
            .ansi256 => |n| std.fmt.bufPrint(buf, "\x1b[38;5;{d}m", .{n}) catch buf[0..0],
            .rgb => |c| std.fmt.bufPrint(buf, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch buf[0..0],
        };
    }
};

fn renderBackground(color: Color, buf: []u8) []const u8 {
    return switch (color) {
        .none => buf[0..0],
        .ansi => |n| std.fmt.bufPrint(buf, "\x1b[{d}m", .{n}) catch buf[0..0],
        .ansi256 => |n| std.fmt.bufPrint(buf, "\x1b[48;5;{d}m", .{n}) catch buf[0..0],
        .rgb => |c| std.fmt.bufPrint(buf, "\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }) catch buf[0..0],
    };
}

/// A rendered ANSI style used to highlight a single token kind.
///
/// `Style` combines a base `Color` with optional bold and dim attributes.
/// The resulting escape sequence is emitted before the token text.
pub const Style = struct {
    fg: Color = .none,
    bg: Color = .none,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,

    pub fn render(self: Style, buf: []u8) []const u8 {
        var out: []const u8 = buf[0..0];
        if (self.fg != .none) {
            out = self.fg.render(buf);
        }
        if (self.bg != .none) {
            const seq = renderBackground(self.bg, buf[out.len..]);
            out = buf[0 .. out.len + seq.len];
        }
        if (self.bold) {
            const seq = std.fmt.bufPrint(buf[out.len..], "\x1b[1m", .{}) catch buf[0..0];
            out = buf[0 .. out.len + seq.len];
        }
        if (self.dim) {
            const seq = std.fmt.bufPrint(buf[out.len..], "\x1b[2m", .{}) catch buf[0..0];
            out = buf[0 .. out.len + seq.len];
        }
        if (self.italic) {
            const seq = std.fmt.bufPrint(buf[out.len..], "\x1b[3m", .{}) catch buf[0..0];
            out = buf[0 .. out.len + seq.len];
        }
        return out;
    }
};

/// Optional token-to-style hook used by the REPL syntax highlighter.
///
/// Returning `null` falls back to the built-in default style for the token kind.
pub const ColorHook = ?*const fn (kind: TokenKind, text: []const u8) ?Style;

/// Highlights the provided Lua source using the configured REPL colors.
///
/// This returns an ANSI-escaped buffer that can be displayed directly by the
/// REPL line editor. It uses the lexer token list and the supplied identifier
/// hook to classify tokens, then applies the configured `ColorConfig` styles.
///
/// Arguments:
/// - allocator: Allocator used to build the highlighted output buffer.
/// - source: The raw Lua source line to highlight.
/// - color_hook: Optional hook used to override styles per token.
pub fn process(
    allocator: std.mem.Allocator,
    source: []const u8,
    color_hook: ColorHook,
) ?[]const u8 {
    var tokens = lexer.lex(allocator, source) catch return null;
    defer tokens.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    var ok = false;
    defer if (!ok) out.deinit(allocator);

    var color_buffer: [64]u8 = undefined;
    var pos: usize = 0;
    for (tokens.items) |token| {
        const kind = tokenKindFromLexer(token.kind) orelse continue;
        if (token.offset > pos) {
            out.appendSlice(allocator, source[pos..token.offset]) catch return null;
        }

        const slice = source[token.offset .. token.offset + token.len];
        const style = highlightStyle(kind, slice, color_hook);
        const color = style.render(color_buffer[0..]);

        if (color.len != 0) {
            out.appendSlice(allocator, color) catch return null;
            out.appendSlice(allocator, slice) catch return null;
            out.appendSlice(allocator, "\x1b[0m") catch return null;
        } else {
            out.appendSlice(allocator, slice) catch return null;
        }

        pos = token.offset + token.len;
    }

    if (pos < source.len) {
        out.appendSlice(allocator, source[pos..]) catch return null;
    }

    ok = true;
    return std.heap.c_allocator.dupeZ(u8, out.items) catch null;
}

fn tokenKindFromLexer(kind: lexer.TokenKind) ?TokenKind {
    return switch (kind) {
        .keyword => .keyword,
        .keyword_value => .keyword_value,
        .builtin => .builtin,
        .name => .name,
        .string => .string,
        .integer => .integer,
        .number => .number,
        .symbol => .symbol,
        .comment => .comment,
        .eos => null,
    };
}

fn highlightStyle(kind: TokenKind, text: []const u8, color_hook: ColorHook) Style {
    if (color_hook) |hook| {
        if (hook(kind, text)) |style| {
            return style;
        }
    }

    return switch (kind) {
        .keyword => .{ .fg = .{ .ansi = 94 }, .bold = true },
        .keyword_value => .{ .fg = .{ .ansi = 96 } },
        .builtin => .{ .fg = .{ .ansi = 36 } },
        .name => .{},
        .string => .{ .fg = .{ .ansi = 32 } },
        .comment => .{ .fg = .{ .ansi = 90 } },
        .integer => .{ .fg = .{ .ansi = 36 } },
        .number => .{ .fg = .{ .ansi = 36 } },
        .symbol => .{ .fg = .{ .ansi = 33 } },
    };
}

test {
    std.testing.refAllDecls(@This());
}
