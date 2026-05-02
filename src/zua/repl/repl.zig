//! Interactive Lua REPL for Zua backed by isocline.
//!
//! This module exposes an embedded REPL that evaluates each line against an
//! existing Zua `State`. Every command runs in a fresh `Context`, so scratch
//! allocations are reclaimed before the next input.
const std = @import("std");
const lua = @import("../../lua/lua.zig");
const State = @import("../state/state.zig").State;
const Context = @import("../state/context.zig").Context;
const Executor = @import("../exec/executor.zig").Executor;

pub const highlight = @import("highlight.zig");
pub const completion = @import("completion.zig");
pub const isocline = @import("../../isocline/isocline.zig");

pub const Repl = @This();

// Exported helpers and callback types used by REPL clients.
pub const Completer = completion.Completer;
pub const CompletionHook = completion.CompletionHook;

const HighlightState = highlight.HighlightState;

pub const Config = @import("config.zig");

/// Runs the interactive Zua REPL session using the provided `State`.
///
/// The REPL supports optional history persistence, syntax highlighting, and
/// tab completion. Each entered line is evaluated in a fresh `Context`, which
/// ensures temporary allocations are reclaimed between commands.
pub fn run(state: *State, config: *Config) !void {
    if (config.history_path) |path| {
        isocline.setHistory(path, config.history_max);
    }

    const welcome_message = std.mem.trim(u8, config.welcome_message orelse "Lua REPL with Zua\nUse shift+tab for multiline input\nUse ctrl+d to exit\n", " \t\r\n");
    try printMessage(state, "", welcome_message);

    // Highlight state lives on the stack; isocline holds a pointer for the
    // duration of the session. The HighlightState outlives every readline call.
    // ctx is set each readline cycle before the call.
    var hl_state = HighlightState{
        .ctx = undefined,
        .config = config,
    };

    // Register the highlighter once for the whole session.
    isocline.setDefaultHighlighter(highlight.highlightCallbackC, &hl_state);
    defer isocline.setDefaultHighlighter(null, null);

    if (config.completion_hook != null or config.lua_completion) {
        var comp_state = completion.CompletionState{
            .state = state,
            .user_hook = config.completion_hook,
            .user_arg = config.completion_arg,
            .lua_enabled = config.lua_completion,
        };
        isocline.setDefaultCompleter(completion.completionCallbackC, &comp_state);
    }
    defer isocline.setDefaultCompleter(null, null);

    while (true) {
        var ctx = Context.init(state);
        defer ctx.deinit();

        hl_state.ctx = &ctx;

        const line = isocline.readline(config.prompt) orelse break;
        defer isocline.freeMemory(@ptrCast(@constCast(line.ptr)));

        const source = std.mem.trim(u8, line, " \t\r\n");
        if (source.len == 0) continue;

        try evalSource(state, &ctx, source, config);
    }
}

// Evaluation

/// Evaluate a single REPL source line.
fn evalSource(state: *State, ctx: *Context, source: []const u8, config: *Config) !void {
    const previous_top = lua.getTop(state.luaState);
    defer lua.setTop(state.luaState, previous_top);

    const wrapped = try tryWrapAsExpression(ctx, source);
    const load_source = wrapped orelse source;
    var executor: Executor = .{};
    const exec_config = Executor.Config{
        .code = .{ .string = load_source },
        .stack_trace = if (config.stack_trace) .arena else .no,
        .take_error_ownership = false,
    };

    executor.eval_untyped(ctx, exec_config) catch {
        const msg = ctx.err orelse "unknown error";
        try printMessage(state, "Error: ", msg);
        return;
    };
    try printResults(state, previous_top);
}

fn tryWrapAsExpression(ctx: *Context, source: []const u8) !?[]const u8 {
    const trimmed_source = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed_source.len == 0) return null;

    const previous_top = lua.getTop(ctx.state.luaState);
    defer lua.setTop(ctx.state.luaState, previous_top);

    const wrapped = try std.fmt.allocPrintSentinel(ctx.arena(), "return {s}", .{trimmed_source}, 0);
    lua.loadString(ctx.state.luaState, wrapped) catch |err| {
        return switch (err) {
            error.Syntax => null,
            else => err,
        };
    };
    return wrapped;
}

// Output helpers

/// Print all values returned by the last Lua expression or statement.
fn printResults(state: *State, previous_top: lua.StackIndex) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer[0..]);
    const top = lua.getTop(state.luaState);
    if (top == previous_top) return;

    var first = true;
    var index: lua.StackIndex = previous_top + 1;
    while (index <= top) : (index += 1) {
        if (!first) try writer.interface.print(", ", .{});
        first = false;

        const abs = lua.absIndex(state.luaState, index);
        if (lua.toDisplayString(state.luaState, abs)) |v| {
            try writer.interface.print("{s}", .{v});
        } else {
            try writer.interface.print("{s}", .{lua.typeName(state.luaState, lua.valueType(state.luaState, abs))});
        }
    }
    try writer.interface.print("\n", .{});
    try writer.interface.flush();
}

/// Print a single REPL message line using a local temporary writer buffer.
fn printMessage(state: *State, prefix: []const u8, message: []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer[0..]);
    try writer.interface.print("{s}{s}\n", .{ prefix, message });
    try writer.interface.flush();
}

test {
    std.testing.refAllDecls(@This());
}
