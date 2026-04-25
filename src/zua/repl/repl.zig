//! Interactive Lua REPL for Zua backed by isocline.
//!
//! Multiline editing is handled natively by isocline (shift-tab / ctrl-enter
//! inserts a continuation line).
//! Each accepted line is evaluated against the provided Zua State in
//! a fresh Context so temporary allocations are reclaimed between commands.
const std = @import("std");
const lua = @import("../../lua/lua.zig");
const State = @import("../state/state.zig").State;
const Context = @import("../state/context.zig").Context;
const Executor = @import("../exec/executor.zig").Executor;

pub const highlight = @import("highlight.zig");
pub const isocline = @import("../../isocline/isocline.zig");

const REPL = @This();

/// Completion callback signature.
///
/// `prefix` is the current word up to the cursor as provided by isocline.
/// The callback adds candidates by calling isocline.addCompletion or
/// isocline.addCompletionEx.
pub const CompletionCallback = ?*const fn (
    cenv: ?*isocline.CompletionEnv,
    prefix: []const u8,
    arg: ?*anyopaque,
) void;

/// REPL configuration options.
pub const Config = struct {
    /// Prompt displayed for each input line.
    prompt: [:0]const u8 = "zua",

    /// Optional completion callback.
    completion_callback: CompletionCallback = null,

    /// Opaque argument forwarded to the completion callback.
    completion_arg: ?*anyopaque = null,

    /// Optional path to a history file.
    history_path: ?[:0]const u8 = null,

    /// Maximum number of history entries. -1 uses the isocline default (200).
    history_max: c_long = -1,

    /// Optional welcome message printed before the first prompt.
    welcome_message: ?[]const u8 = null,

    /// Optional per-token style hook for syntax highlighting.
    color_hook: highlight.ColorHook = null,
};

// Completion and highlight state forwarded through isocline opaque arg pointers.

const CompletionState = struct {
    callback: CompletionCallback,
    arg: ?*anyopaque,
};

const HighlightState = struct {
    allocator: std.mem.Allocator,
    color_hook: highlight.ColorHook,
};

// C-calling-convention callbacks registered with isocline.

fn completionCallbackC(cenv: ?*isocline.CompletionEnv, prefix: [*c]const u8) callconv(.c) void {
    const raw_arg = isocline.completionArg(cenv) orelse return;
    const state: *CompletionState = @ptrCast(@alignCast(raw_arg));
    const cb = state.callback orelse return;
    cb(cenv, std.mem.span(prefix), state.arg);
}

fn highlightCallbackC(
    henv: ?*isocline.HighlightEnv,
    input: [*c]const u8,
    arg: ?*anyopaque,
) callconv(.c) void {
    const state: *HighlightState = @ptrCast(@alignCast(arg orelse return));
    const source = std.mem.span(input);
    const formatted = highlight.process(state.allocator, source, state.color_hook) orelse return;
    defer state.allocator.free(formatted);
    // formatted is null-terminated; pass pointer as C string.
    isocline.highlightFormatted(henv, input, formatted.ptr);
}

/// Runs the interactive Zua REPL session using the provided State.
///
/// Returns !void; propagates I/O errors from history file operations.
pub fn run(state: *State, config: Config) !void {
    var stdout_buffer: [4096]u8 = undefined;

    if (config.history_path) |path| {
        // Touch the file so historyLoad does not fail on first run.
        const file = std.Io.Dir.cwd().createFile(state.io, path, .{}) catch |err| return err;
        file.close(state.io);
        isocline.setHistory(path, config.history_max);
    }

    try printWelcome(state, &stdout_buffer, config.welcome_message);

    // Highlight state lives on the stack; isocline holds a pointer for the
    // duration of the session. The HighlightState outlives every readline call.
    var hl_state = HighlightState{
        .allocator = state.allocator,
        .color_hook = config.color_hook,
    };

    // Register the highlighter once for the whole session.
    isocline.setDefaultHighlighter(highlightCallbackC, &hl_state);
    defer isocline.setDefaultHighlighter(null, null);

    var comp_state: CompletionState = undefined;
    if (config.completion_callback != null) {
        comp_state = .{
            .callback = config.completion_callback,
            .arg = config.completion_arg,
        };
        isocline.setDefaultCompleter(completionCallbackC, &comp_state);
        defer isocline.setDefaultCompleter(null, null);
    }

    while (true) {
        const line = isocline.readline(config.prompt) orelse break;
        defer isocline.freeMemory(@ptrCast(@constCast(line.ptr)));

        const source = std.mem.trim(u8, line, " \t\r\n");
        if (source.len == 0) continue;

        try evalSource(state, source, &stdout_buffer);
    }

    if (config.history_path) |path| {
        // isocline persists history automatically when a filename is set via
        // setHistory, but we call it again to flush any remaining entries.
        _ = path;
    }
}

// Evaluation

fn evalSource(state: *State, source: []const u8, stdout_buffer: *[4096]u8) !void {
    var ctx = Context.init(state);
    defer ctx.deinit();

    const previous_top = lua.getTop(state.luaState);
    defer lua.setTop(state.luaState, previous_top);

    if (canLoadAsExpression(state, source) catch false) {
        const expr_source = expressionInput(source);
        const wrapped = try allocateReturnSource(state, expr_source);
        defer state.allocator.free(wrapped);

        lua.loadString(state.luaState, wrapped[0 .. wrapped.len - 1 :0]) catch {
            const msg = lua.toDisplayString(state.luaState, -1) orelse "unknown error";
            try printMessage(state, stdout_buffer, "Syntax error: ", msg);
            return;
        };

        lua.protectedCall(state.luaState, 0, lua.MULT_RETURN, 0) catch {
            const msg = lua.toDisplayString(state.luaState, -1) orelse "unknown error";
            try printMessage(state, stdout_buffer, "Runtime error: ", msg);
            return;
        };

        try printResults(state, stdout_buffer, previous_top);
        return;
    }

    var executor: Executor = .{};
    const exec_config = Executor.Config{
        .code = .{ .string = source },
        .stack_trace = .no,
        .take_error_ownership = false,
    };

    executor.execute(&ctx, exec_config) catch {
        const msg = ctx.err orelse "unknown error";
        try printMessage(state, stdout_buffer, "Error: ", msg);
        return;
    };

    try printResults(state, stdout_buffer, previous_top);
}

fn expressionInput(source: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len != 0 and trimmed[0] == '=') {
        return std.mem.trim(u8, trimmed[1..], " \t\r\n");
    }
    return source;
}

fn canLoadAsExpression(state: *State, source: []const u8) !bool {
    const expr_source = expressionInput(source);
    if (expr_source.len == 0) return false;

    const previous_top = lua.getTop(state.luaState);
    defer lua.setTop(state.luaState, previous_top);

    const prefix = "return ";
    const wrapped = try state.allocator.alloc(u8, prefix.len + expr_source.len + 1);
    defer state.allocator.free(wrapped);

    @memcpy(wrapped[0..prefix.len], prefix);
    @memcpy(wrapped[prefix.len .. prefix.len + expr_source.len], expr_source);
    wrapped[wrapped.len - 1] = 0;

    lua.loadString(state.luaState, wrapped[0 .. wrapped.len - 1 :0]) catch |err| {
        return switch (err) {
            error.Syntax => false,
            else => err,
        };
    };
    return true;
}

fn allocateReturnSource(state: *State, source: []const u8) ![]u8 {
    const prefix = "return ";
    const buffer = try state.allocator.alloc(u8, prefix.len + source.len + 1);
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len .. prefix.len + source.len], source);
    buffer[buffer.len - 1] = 0;
    return buffer;
}

// Output helpers

fn printResults(state: *State, stdout_buffer: *[4096]u8, previous_top: lua.StackIndex) !void {
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer);
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

fn printWelcome(state: *State, stdout_buffer: *[4096]u8, welcome_message: ?[]const u8) !void {
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer);
    const msg = welcome_message orelse "Lua REPL with Zua\n";
    try writer.interface.print("{s}", .{msg});
    try writer.interface.flush();
}

fn printMessage(state: *State, stdout_buffer: *[4096]u8, prefix: []const u8, message: []const u8) !void {
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer);
    try writer.interface.print("{s}{s}\n", .{ prefix, message });
    try writer.interface.flush();
}

test {
    std.testing.refAllDecls(@This());
}
