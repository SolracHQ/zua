const std = @import("std");

const completion = @import("completion.zig");
const highlight = @import("highlight.zig");

const Fn = @import("../typed/fn.zig").Fn;
const Meta = @import("../meta.zig");
const Native = @import("../functions/native.zig");
const Object = @import("../typed/object.zig").Object;

const Completer = completion.Completer;
const CompletionHook = completion.CompletionHook;

/// REPL configuration options.
pub const Config = @This();

pub const ZUA_META = Meta.Object(Config, .{
    .set_color = Native.new(setColor, .{}).withDescriptions(&.{
        .{ .name = "kind", .description = "Token kind to color." },
        .{ .name = "color", .description = "Color value as ANSI int, hex string, color name, or {r,g,b} table." },
    }).withDescription("Set a color override for a token kind."),
    .set_style = Native.new(setStyle, .{}).withDescriptions(&.{
        .{ .name = "kind", .description = "Token kind to style." },
        .{ .name = "style", .description = "Style table with optional fg, bg, bold, dim, italic fields." },
    }).withDescription("Set a full style override for a token kind."),
    .set_style_hook = Native.new(setStyleHook, .{}).withDescriptions(&.{
        .{ .name = "hook", .description = "Function receiving (kind, text) and returning a Style table or nil." },
    }).withDescription("Set the Lua-side syntax highlighting hook."),
    .set_completion_hook = Native.new(setLuaCompletionHook, .{}).withDescriptions(&.{
        .{ .name = "hook", .description = "Function receiving (completer, prefix) and calling completer:add/addEx to publish candidates." },
    }).withDescription("Set the Lua-side tab completion hook."),
    .set_runtime_completion = Native.new(setRuntimeCompletion, .{}).withDescriptions(&.{
        .{ .name = "enabled", .description = "Whether live Lua runtime completion is enabled." },
    }).withDescription("Enable or disable live Lua runtime completion for chained identifiers."),
    .__gc = gc,
}).withDescription("REPL configuration with runtime Lua-facing controls.")
    .withName("ReplConfig");

/// Prompt displayed for each input line.
prompt: [:0]const u8 = "zua",

/// Optional completion callback for the embedded REPL.
///
/// The callback receives the current completion prefix and a
/// `*Completer` helper. Use it to add custom completion candidates.
/// The `Completer` carries a `*Context` so the hook can query the
/// Lua runtime through it if desired.
completion_hook: CompletionHook = null,

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
style_hook: highlight.ColorHook = null,

/// When enabled, the REPL resolves chained Lua identifiers against the
/// live runtime and completes globals, fields, and methods.
///
/// Runtime completion is performed before the Zig and Lua completion
/// hooks, so custom hooks can augment or override results.
runtime_completion: bool = true,

/// Per-kind style overrides. Set via repl:set_color or repl:set_style from Lua.
style_overrides: std.EnumArray(highlight.TokenKind, ?highlight.Style) = .initFill(null),

/// Lua-side style hook called in resolveStyle, before the Zig style_hook.
///
/// Receives the token kind and the token text. Returns a Style table or nil.
lua_style_hook: ?Fn(.{ highlight.TokenKind, []const u8 }, ?highlight.Style) = null,

/// Lua-side completion hook. Called when set, after runtime completion.
///
/// Receives the session `Completer` handle and the input prefix.
lua_completion_hook: ?Fn(.{ Object(Completer), []const u8 }, void) = null,

// Lua-facing methods

fn setColor(self: *Config, kind: highlight.TokenKind, color: highlight.Color) void {
    self.style_overrides.set(kind, highlight.Style{ .fg = color });
}

fn setStyle(self: *Config, kind: highlight.TokenKind, style: highlight.Style) void {
    self.style_overrides.set(kind, style);
}

fn setStyleHook(self: *Config, hook: Fn(.{ highlight.TokenKind, []const u8 }, ?highlight.Style)) void {
    if (self.lua_style_hook) |prev| prev.release();
    self.lua_style_hook = hook.takeOwnership();
}

fn setLuaCompletionHook(self: *Config, hook: Fn(.{ Object(Completer), []const u8 }, void)) void {
    if (self.lua_completion_hook) |prev| prev.release();
    self.lua_completion_hook = hook.takeOwnership();
}

fn setRuntimeCompletion(self: *Config, enabled: bool) void {
    self.runtime_completion = enabled;
}

fn gc(self: *Config) void {
    if (self.lua_style_hook) |hook| hook.release();
    if (self.lua_completion_hook) |hook| hook.release();
}
