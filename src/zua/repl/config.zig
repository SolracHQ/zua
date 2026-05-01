const std = @import("std");

const completion = @import("completion.zig");
const highlight = @import("highlight.zig");

const Meta = @import("../meta.zig");

const Completer = completion.Completer;
const CompletionHook = completion.CompletionHook;

/// REPL configuration options.
pub const Config = @This();

pub const ZUA_META = Meta.Object(Config, .{
    .setColor = setColor,
    .setStyle = setStyle,
});

/// Prompt displayed for each input line.
prompt: [:0]const u8 = "zua",

/// Optional completion callback for the embedded REPL.
///
/// The callback receives the current completion prefix and a stable
/// `*zua.Repl.Completer` helper. Use it to add custom completion candidates
/// that are not derived from the live Lua runtime.
completion_hook: CompletionHook = null,

/// Opaque argument forwarded to the completion callback.
completion_arg: ?*anyopaque = null,

/// Optional path to a history file.
history_path: ?[:0]const u8 = null,

/// Maximum number of history entries. -1 uses the isocline default (200).
history_max: c_long = -1,

/// Optional welcome message printed once at startup.
welcome_message: ?[]const u8 = null,

/// Enable stack trace capture for runtime errors.
///
/// When enabled, the REPL uses the executor's stack trace
/// mode so tracebacks are available for errors.
stack_trace: bool = false,

/// Optional per-token style hook for syntax highlighting.
color_hook: highlight.ColorHook = null,

/// When enabled, the REPL resolves chained Lua identifiers against the
/// live runtime and completes globals, fields, and methods.
///
/// If configured, runtime completion is performed before the optional
/// `completion_hook`, so your custom hook can augment or override results.
lua_completion: bool = false,

/// Per-kind style overrides. Set via repl:set_color or repl:set_style from Lua.
style_overrides: std.EnumArray(highlight.TokenKind, ?highlight.Style) = .initFill(null),

/// Lua-side color hook. Called when set, before the Zig color_hook.
lua_color_hook: ?*anyopaque = null,

/// Lua-side completion hook. Called when set, after runtime completion.
lua_completion_hook: ?*anyopaque = null,

// Lua-facing methods

/// repl:set_color(kind, color)
///
/// Sets a color override for a token kind. `color` accepts an ANSI integer,
/// "#rrggbb" hex string, named color string, or {r,g,b} table.
fn setColor(self: *Config, kind: highlight.TokenKind, color: highlight.Color) void {
    self.style_overrides.set(kind, highlight.Style{ .fg = color });
}

/// repl:set_style(kind, style)
///
/// Sets a full style override for a token kind. `style` is a table with
/// optional fg, bg, bold, dim, italic fields.
fn setStyle(self: *Config, kind: highlight.TokenKind, style: highlight.Style) void {
    self.style_overrides.set(kind, style);
}
