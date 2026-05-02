//! ANSI syntax highlighting helpers for the embedded REPL.
//!
//! Tokens are classified by the lexer and mapped to bbcode style tags
//! understood by isocline's ic_highlight_formatted. The output string
//! must match the raw input character-for-character outside of the tags.
const std = @import("std");
const isocline = @import("../../isocline/isocline.zig");
const lexer = @import("lexer.zig");
const Config = @import("config.zig");
const Context = @import("../state/context.zig");
const lua = @import("../../lua/lua.zig");
const Meta = @import("../meta.zig");
const Mapper = @import("../mapper/mapper.zig");

const Primitive = Mapper.Decoder.Primitive;

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

    pub const ZUA_META = Meta.strEnum(TokenKind, .{});
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

    pub const ZUA_META = Meta.Table(Color, .{}).withDecode(decodeColor);

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

fn decodeColor(ctx: *Context, prim: Primitive) !?Color {
    return switch (prim) {
        .integer => |n| Color{ .ansi = @intCast(n) },
        .string => |s| {
            if (s.len > 0 and s[0] == '#') {
                if (s.len != 7) return ctx.failTyped(?Color, "invalid RGB hex color, expected #rrggbb");
                const r = try std.fmt.parseInt(u8, s[1..3], 16);
                const g = try std.fmt.parseInt(u8, s[3..5], 16);
                const b = try std.fmt.parseInt(u8, s[5..7], 16);
                return Color{ .rgb = .{ .r = r, .g = g, .b = b } };
            }
            const ansi = ansiFromName(s) orelse return ctx.failTyped(?Color, "unknown color name");
            return Color{ .ansi = ansi };
        },
        .table => |t| {
            const r = try t.get(ctx, "r", u8);
            const g = try t.get(ctx, "g", u8);
            const b = try t.get(ctx, "b", u8);
            return Color{ .rgb = .{ .r = r, .g = g, .b = b } };
        },
        else => null,
    };
}

fn ansiFromName(name: []const u8) ?u8 {
    if (std.mem.eql(u8, name, "black")) return 0;
    if (std.mem.eql(u8, name, "red")) return 1;
    if (std.mem.eql(u8, name, "green")) return 2;
    if (std.mem.eql(u8, name, "yellow")) return 3;
    if (std.mem.eql(u8, name, "blue")) return 4;
    if (std.mem.eql(u8, name, "magenta")) return 5;
    if (std.mem.eql(u8, name, "purple")) return 5;
    if (std.mem.eql(u8, name, "cyan")) return 6;
    if (std.mem.eql(u8, name, "white")) return 7;
    if (std.mem.eql(u8, name, "bright_black") or std.mem.eql(u8, name, "gray") or std.mem.eql(u8, name, "grey")) return 8;
    if (std.mem.eql(u8, name, "bright_red")) return 9;
    if (std.mem.eql(u8, name, "bright_green")) return 10;
    if (std.mem.eql(u8, name, "bright_yellow")) return 11;
    if (std.mem.eql(u8, name, "bright_blue")) return 12;
    if (std.mem.eql(u8, name, "bright_magenta")) return 13;
    if (std.mem.eql(u8, name, "bright_cyan")) return 14;
    if (std.mem.eql(u8, name, "bright_white")) return 15;
    return null;
}

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
pub const ColorHook = ?*const fn (ctx: *Context, kind: TokenKind, text: []const u8) ?Style;

/// Highlight state forwarded through isocline opaque arg pointers.
pub const HighlightState = struct {
    ctx: *Context,
    config: *Config,
};

/// C callback wrapper for isocline syntax highlighting.
///
/// The callback delegates to `process` and forwards the formatted bbcode
/// result back to isocline.
pub fn highlightCallbackC(
    henv: ?*isocline.HighlightEnv,
    input: [*c]const u8,
    arg: ?*anyopaque,
) callconv(.c) void {
    const hs: *HighlightState = @ptrCast(@alignCast(arg orelse return));
    const previous_top = lua.getTop(hs.ctx.state.luaState);
    defer lua.setTop(hs.ctx.state.luaState, previous_top);
    const source = std.mem.span(input);
    const formatted = process(hs.ctx, source, &hs.config.style_overrides, hs.config) orelse return;
    defer hs.ctx.arena().free(formatted);
    // formatted is null-terminated; pass pointer as C string.
    isocline.highlightFormatted(henv, input, formatted.ptr);
}

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

fn resolveStyle(
    kind: TokenKind,
    text: []const u8,
    style_overrides: *const std.EnumArray(TokenKind, ?Style),
    config: *Config,
    ctx: *Context,
) Style {
    if (style_overrides.get(kind)) |style| return style;
    if (config.lua_style_hook) |hook| {
        if (hook.call(ctx, .{ kind, text }) catch null) |style| return style;
    }
    if (config.style_hook) |hook| {
        if (hook(ctx, kind, text)) |style| return style;
    }
    return defaultStyle(kind);
}

/// Build a bbcode-annotated copy of `source` suitable for ic_highlight_formatted.
///
/// The returned slice is null-terminated and owned by the caller (allocated with
/// `allocator`). Returns null on allocation failure or lexer error.
pub fn process(
    ctx: *Context,
    source: []const u8,
    style_overrides: *const std.EnumArray(TokenKind, ?Style),
    config: *Config,
) ?[]const u8 {
    const arena = ctx.arena();
    var tokens = lexer.lex(arena, source) catch return null;
    defer tokens.deinit(arena);

    // Pre-size: bbcode tags can add ~30 bytes per token in the worst case.
    var out = std.ArrayList(u8).initCapacity(arena, source.len + tokens.items.len * 32) catch return null;
    var ok = false;
    defer if (!ok) out.deinit(arena);

    var pos: usize = 0;
    for (tokens.items) |token| {
        const kind = tokenKindFromLexer(token.kind) orelse continue;

        // Emit any gap between the last token and this one verbatim.
        if (token.offset > pos) {
            out.appendSlice(arena, source[pos..token.offset]) catch return null;
        }

        const slice = source[token.offset .. token.offset + token.len];
        const style = resolveStyle(kind, slice, style_overrides, config, ctx);

        if (!style.isEmpty()) {
            style.writeOpenTag(arena, &out) catch return null;
            out.appendSlice(arena, slice) catch return null;
            style.writeCloseTag(arena, &out) catch return null;
        } else {
            out.appendSlice(arena, slice) catch return null;
        }

        pos = token.offset + token.len;
    }

    if (pos < source.len) {
        out.appendSlice(arena, source[pos..]) catch return null;
    }

    // Null-terminate so the C API can use the pointer directly.
    out.append(arena, 0) catch return null;

    ok = true;
    const raw = out.toOwnedSlice(arena) catch return null;
    // Return the slice without the sentinel so callers get a plain []const u8,
    // but the underlying buffer is still null-terminated for C interop.
    return raw;
}

test {
    std.testing.refAllDecls(@This());
}
