//! ANSI syntax highlighting helpers for the embedded REPL.
//!
//! This module maps lexer token kinds to color and style sequences and
//! renders highlighted source text for the current REPL line.
const std = @import("std");
const lexer = @import("lexer.zig");

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

/// A rendered ANSI style used to highlight a single token kind.
///
/// `Style` combines a base `Color` with optional bold and dim attributes.
/// The resulting escape sequence is emitted before the token text.
pub const Style = struct {
    color: Color = .none,
    bold: bool = false,
    dim: bool = false,

    pub fn render(self: Style, buf: []u8) []const u8 {
        var out: []const u8 = buf[0..0];
        if (self.color != .none) {
            out = self.color.render(buf);
        }
        if (self.bold) {
            const seq = std.fmt.bufPrint(buf[out.len..], "\x1b[1m", .{}) catch buf[0..0];
            out = buf[0 .. out.len + seq.len];
        }
        if (self.dim) {
            const seq = std.fmt.bufPrint(buf[out.len..], "\x1b[2m", .{}) catch buf[0..0];
            out = buf[0 .. out.len + seq.len];
        }
        return out;
    }
};

/// Syntax highlight configuration used by the REPL.
///
/// Each field controls the ANSI style emitted for a specific token kind.
/// The `custom` hook may classify identifiers as `.custom` and return a
/// `Color` to render those names specially.
pub const ColorConfig = struct {
    keyword: Style = .{ .color = .{ .ansi = 94 }, .bold = true },
    keyword_value: Style = .{ .color = .{ .ansi = 96 } },
    builtin: Style = .{ .color = .{ .ansi = 36 } },
    custom: ?*const fn ([]const u8) Color = null,
    name: Style = .{},
    string: Style = .{ .color = .{ .ansi = 32 } },
    integer: Style = .{ .color = .{ .ansi = 36 } },
    number: Style = .{ .color = .{ .ansi = 36 } },
    symbol: Style = .{ .color = .{ .ansi = 33 } },
    comment: Style = .{ .color = .{ .ansi = 90 } },
};

/// Highlights the provided Lua source using the configured REPL colors.
///
/// This returns an ANSI-escaped buffer that can be displayed directly by the
/// REPL line editor. It uses the lexer token list and the supplied identifier
/// hook to classify tokens, then applies the configured `ColorConfig` styles.
///
/// Arguments:
/// - allocator: Allocator used to build the highlighted output buffer.
/// - source: The raw Lua source line to highlight.
/// - config: Color configuration for each token kind.
/// - custom_hook: Optional identifier hook used for `.custom` token classification.
pub fn process(
    allocator: std.mem.Allocator,
    source: []const u8,
    config: ColorConfig,
    custom_hook: lexer.IdentifierHook,
) ?[]const u8 {
    var tokens = lexer.lexWithHook(allocator, source, custom_hook) catch return null;
    defer tokens.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    var ok = false;
    defer if (!ok) out.deinit(allocator);

    var color_buffer: [64]u8 = undefined;
    var pos: usize = 0;
    for (tokens.items) |token| {
        if (token.kind == lexer.TokenKind.eos) continue;
        if (token.offset > pos) {
            out.appendSlice(allocator, source[pos..token.offset]) catch return null;
        }

        const slice = source[token.offset .. token.offset + token.len];
        const style = highlightStyle(token.kind, slice, config);
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

fn highlightStyle(kind: lexer.TokenKind, text: []const u8, config: ColorConfig) Style {
    return switch (kind) {
        .keyword => config.keyword,
        .keyword_value => config.keyword_value,
        .builtin => config.builtin,
        .custom => if (config.custom) |hook| .{ .color = hook(text) } else config.name,
        .string => config.string,
        .comment => config.comment,
        .integer => config.integer,
        .number => config.number,
        .symbol => config.symbol,
        .name => config.name,
        .eos => .{},
    };
}
