//! ANSI syntax highlighting helpers for the embedded REPL.
//!
//! Tokens are classified by the lexer and mapped to bbcode style tags
//! understood by isocline's ic_highlight_formatted. The output string
//! must match the raw input character-for-character outside of the tags.
const std = @import("std");
const lexer = @import("lexer.zig");

// Token kinds

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

// Color and style types

/// An ANSI/RGB color value used by a style.
///
/// .none leaves the channel at the terminal default.
/// .ansi uses a standard 8/16-color ANSI index.
/// .ansi256 uses the 256-color xterm palette.
/// .rgb uses a 24-bit color expressed as separate r/g/b bytes.
pub const Color = union(enum) {
    none,
    ansi: u8,
    ansi256: u8,
    rgb: struct { r: u8, g: u8, b: u8 },

    pub fn writeBbcodeFg(self: Color, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        const result = switch (self) {
            .none => return,
            .ansi => |n| try std.fmt.allocPrint(allocator, "ansi-color={d} ", .{n}),
            .ansi256 => |n| try std.fmt.allocPrint(allocator, "ansi-color={d} ", .{n}),
            .rgb => |c| try std.fmt.allocPrint(allocator, "#{x:0>2}{x:0>2}{x:0>2} ", .{ c.r, c.g, c.b }),
        };
        defer allocator.free(result);
        try out.appendSlice(allocator, result);
    }

    pub fn writeBbcodeBg(self: Color, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        const result = switch (self) {
            .none => return,
            .ansi => |n| try std.fmt.allocPrint(allocator, "on ansi-color={d} ", .{n}),
            .ansi256 => |n| try std.fmt.allocPrint(allocator, "on ansi-color={d} ", .{n}),
            .rgb => |c| try std.fmt.allocPrint(allocator, "on #{x:0>2}{x:0>2}{x:0>2} ", .{ c.r, c.g, c.b }),
        };
        defer allocator.free(result);
        try out.appendSlice(allocator, result);
    }
};

/// A renderable style combining colors and text attributes.
pub const Style = struct {
    fg: Color = .none,
    bg: Color = .none,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,

    pub fn isEmpty(self: Style) bool {
        return self.fg == .none and
            self.bg == .none and
            !self.bold and
            !self.dim and
            !self.italic;
    }

    /// Write the opening bbcode tag for this style, e.g. "[#ff0000 b]".
    /// Does nothing when the style is empty.
    pub fn writeOpenTag(self: Style, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        if (self.isEmpty()) return;
        try out.append(allocator, '[');
        try self.fg.writeBbcodeFg(allocator, out);
        try self.bg.writeBbcodeBg(allocator, out);
        if (self.bold) try out.appendSlice(allocator, "b ");

        if (self.italic) try out.appendSlice(allocator, "i ");
        if (self.dim) try out.appendSlice(allocator, "dim ");
        try out.append(allocator, ']');
    }

    pub fn writeCloseTag(_: Style, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(allocator, "[/]");
    }
};

/// Optional per-token style override hook.
///
/// Return null to fall back to the built-in default for the kind.
pub const ColorHook = ?*const fn (kind: TokenKind, text: []const u8) ?Style;

// Internal helpers

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

fn defaultStyle(kind: TokenKind) Style {
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

fn resolveStyle(kind: TokenKind, text: []const u8, hook: ColorHook) Style {
    if (hook) |f| {
        if (f(kind, text)) |s| return s;
    }
    return defaultStyle(kind);
}

/// Build a bbcode-annotated copy of `source` suitable for ic_highlight_formatted.
///
/// The returned slice is null-terminated and owned by the caller (allocated with
/// `allocator`). Returns null on allocation failure or lexer error.
pub fn process(
    allocator: std.mem.Allocator,
    source: []const u8,
    color_hook: ColorHook,
) ?[]const u8 {
    var tokens = lexer.lex(allocator, source) catch return null;
    defer tokens.deinit(allocator);

    // Pre-size: bbcode tags can add ~30 bytes per token in the worst case.
    var out = std.ArrayList(u8).initCapacity(allocator, source.len + tokens.items.len * 32) catch return null;
    var ok = false;
    defer if (!ok) out.deinit(allocator);

    var pos: usize = 0;
    for (tokens.items) |token| {
        const kind = tokenKindFromLexer(token.kind) orelse continue;

        // Emit any gap between the last token and this one verbatim.
        if (token.offset > pos) {
            out.appendSlice(allocator, source[pos..token.offset]) catch return null;
        }

        const slice = source[token.offset .. token.offset + token.len];
        const style = resolveStyle(kind, slice, color_hook);

        if (!style.isEmpty()) {
            style.writeOpenTag(allocator, &out) catch return null;
            out.appendSlice(allocator, slice) catch return null;
            style.writeCloseTag(allocator, &out) catch return null;
        } else {
            out.appendSlice(allocator, slice) catch return null;
        }

        pos = token.offset + token.len;
    }

    if (pos < source.len) {
        out.appendSlice(allocator, source[pos..]) catch return null;
    }

    // Null-terminate so the C API can use the pointer directly.
    out.append(allocator, 0) catch return null;

    ok = true;
    const raw = out.toOwnedSlice(allocator) catch return null;
    // Return the slice without the sentinel so callers get a plain []const u8,
    // but the underlying buffer is still null-terminated for C interop.
    return raw[0 .. raw.len - 1];
}

test {
    std.testing.refAllDecls(@This());
}
