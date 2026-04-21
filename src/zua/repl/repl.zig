//! Interactive Lua REPL for Zua using linenoise.
//!
//! This module exposes a small embedded REPL that evaluates each line
//! against an existing Zua `State`. Each evaluation uses a fresh `Context`
//! so temporary allocations are cleared after every command.
const std = @import("std");
const lua = @import("../../lua/lua.zig");
const lexer = @import("lexer.zig");
const State = @import("../state/state.zig").State;
const Context = @import("../state/context.zig").Context;
const Executor = @import("../exec/executor.zig").Executor;

// Export repl components since callbacks may need to reference them
pub const highlight = @import("highlight.zig");
pub const linenoise = @import("../../linenoise/linenoise.zig");

const REPL = @This();

/// Optional callback used by the REPL to populate completion candidates.
///
/// `buffer` is the current input line. The callback may add suggestions to
/// `completions` for the line currently being edited.
pub const CompletionCallback = ?*const fn (buffer: []const u8, completions: *linenoise.Completions) void;

/// REPL configuration options.
pub const Config = struct {
    /// Prompt displayed for the first line of input.
    prompt: [:0]const u8 = "zua> ",

    /// Prompt displayed when input spans multiple lines.
    continuation_prompt: [:0]const u8 = "...> ",

    /// Optional completion callback used by the embedded linenoise editor.
    completion_callback: CompletionCallback = null,

    /// Optional path to a history file to load and save command history.
    history_path: ?[:0]const u8 = null,

    /// Optional welcome message printed when the REPL starts.
    welcome_message: ?[]const u8 = null,

    /// Optional custom lexer hook for user-defined identifier classification.
    identifier_hook: lexer.IdentifierHook = null,

    /// Optional ANSI color configuration for syntax highlighting.
    color_config: ?highlight.ColorConfig = null,
};

/// The registered tab completion callback.
/// This is stored globally because the linenoise API only supports one
/// completion callback at a time.
var completion_callback: CompletionCallback = null;

/// Active syntax highlighting colors used by the current REPL session.
/// This global exists to bridge the lexer/highlighter to the linenoise callback.
var active_color_config: highlight.ColorConfig = .{};
var active_identifier_hook: lexer.IdentifierHook = null;

var running: bool = false;

/// Runs the interactive Zua REPL session using the provided `State`.
///
/// Each entered command is evaluated in a fresh `Context`, which ensures
/// temporary allocations are reclaimed between commands. The REPL supports
/// multi-line input, optional history persistence, syntax highlighting, and
/// optional completion callbacks.
///
/// Arguments:
/// - state: The global Zua state used for Lua execution.
/// - config: Runtime configuration for prompt text, history, and completion.
///
/// Returns:
/// - !void: `error.Failed` on I/O or initialization failure.
pub fn run(state: *State, config: Config) !void {
    var stdout_buffer: [4096]u8 = undefined;

    if (config.history_path) |path| {
        // create the file if not already present
        const file = std.Io.Dir.cwd().createFile(state.io, path, .{}) catch |err| {
            return err;
        };
        file.close(state.io);
        try linenoise.historyLoad(path);
    }

    try printWelcome(state, &stdout_buffer, config.welcome_message);

    active_color_config = if (config.color_config) |cfg| cfg else .{};
    active_identifier_hook = config.identifier_hook;
    linenoise.setMultiLine(true);
    linenoise.setHighlightCallback(highlightCallbackC);

    if (config.completion_callback) |callback| {
        completion_callback = callback;
        linenoise.setCompletionCallback(completionCallbackC);
    }

    running = true;
    while (running) {
        const source = (try readChunk(state, config)) orelse break;
        defer state.allocator.free(source);

        if (std.mem.trim(u8, source, " \t\r\n").len == 0) continue;

        const history_entry = try state.allocator.dupeZ(u8, source);
        defer state.allocator.free(history_entry);
        _ = linenoise.historyAdd(history_entry);

        try evalSource(state, source, &stdout_buffer);
    }

    if (config.history_path) |path| {
        try linenoise.historySave(path);
    }
}

/// Reads one REPL input chunk, including continuation lines.
///
/// This returns a single owned buffer containing the full command entered by
/// the user, until the input is complete or EOF is reached.
fn readChunk(state: *State, config: Config) !?[]u8 {
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(state.allocator);

    var current_prompt = config.prompt;
    while (true) {
        const line = linenoise.readLine(current_prompt) orelse {
            if (source.items.len == 0) return null;
            return try source.toOwnedSlice(state.allocator);
        };
        defer linenoise.freeLine(line);

        if (source.items.len != 0) {
            try source.append(state.allocator, '\n');
        }
        try source.appendSlice(state.allocator, line);

        if (isChunkComplete(state, source.items)) {
            return try source.toOwnedSlice(state.allocator);
        }

        current_prompt = config.continuation_prompt;
    }
}

/// Checks whether the current source is a complete Lua chunk.
///
/// Expressions starting with `=` are accepted if they can be rewritten as a
/// valid `return` statement. Otherwise this defers to Lua syntax parsing for
/// statement completeness.
fn isChunkComplete(state: *State, source: []const u8) bool {
    if (canLoadAsExpression(state, source) catch false) return true;
    return checkStatementCompleteness(state, source);
}

/// Attempts to load the source as a Lua statement and detects an unfinished
/// chunk when the parser reports an unexpected end-of-file.
fn checkStatementCompleteness(state: *State, source: []const u8) bool {
    const previous_top = lua.getTop(state.luaState);
    defer lua.setTop(state.luaState, previous_top);

    const chunk = state.allocator.dupeZ(u8, source) catch return true;
    defer state.allocator.free(chunk);

    lua.loadString(state.luaState, chunk) catch |err| {
        if (err == error.Syntax) {
            if (lua.toString(state.luaState, -1)) |msg| {
                if (std.mem.endsWith(u8, msg, "<eof>")) {
                    return false;
                }
            }
        }
        return true;
    };

    return true;
}

/// Evaluates a single REPL command and prints any result or error.
///
/// This creates a temporary `Context` for the command and restores the Lua
/// stack top before returning.
fn evalSource(state: *State, source: []const u8, stdout_buffer: *[4096]u8) !void {
    var ctx = Context.init(state);
    defer ctx.deinit();

    const previous_top = lua.getTop(state.luaState);
    defer lua.setTop(state.luaState, previous_top);

    const can_expr = canLoadAsExpression(state, source) catch false;
    if (can_expr) {
        const expr_source = expressionInput(source);
        const wrapped = try allocateReturnSource(state, expr_source);
        defer state.allocator.free(wrapped);

        lua.loadString(state.luaState, wrapped[0 .. wrapped.len - 1 :0]) catch {
            const raw_message = lua.toDisplayString(state.luaState, -1) orelse "unknown error";
            try printMessage(state, stdout_buffer, "Syntax error: ", raw_message);
            return;
        };

        lua.protectedCall(state.luaState, 0, lua.MULT_RETURN, 0) catch {
            const raw_message = lua.toDisplayString(state.luaState, -1) orelse "unknown error";
            try printMessage(state, stdout_buffer, "Runtime error: ", raw_message);
            return;
        };

        try printResults(state, stdout_buffer, previous_top);
        return;
    }

    var executor: Executor = .{};
    var config: Executor.Config = undefined;
    config = Executor.Config{ .code = .{ .string = source }, .stack_trace = .no, .take_error_ownership = false };

    executor.execute(&ctx, config) catch {
        const message = ctx.err orelse "unknown error";
        try printMessage(state, stdout_buffer, "Error: ", message);
        return;
    };

    try printResults(state, stdout_buffer, previous_top);
}

/// Normalizes REPL expression input by stripping a leading `=` prefix.
///
/// `=expr` is treated as `return expr` for convenience in the interactive prompt.
fn expressionInput(source: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len != 0 and trimmed[0] == '=') {
        return std.mem.trim(u8, trimmed[1..], " \t\r\n");
    }
    return source;
}

/// Checks whether the given source can be parsed as an expression in the REPL.
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

/// Allocates a null-terminated source buffer for `return` expressions.
fn allocateReturnSource(state: *State, source: []const u8) ![]u8 {
    const prefix = "return ";
    const buffer = try state.allocator.alloc(u8, prefix.len + source.len + 1);
    @memcpy(buffer[0..prefix.len], prefix);
    @memcpy(buffer[prefix.len .. prefix.len + source.len], source);
    buffer[buffer.len - 1] = 0;
    return buffer;
}

/// Prints all values returned by the last Lua expression or statement.
fn printResults(state: *State, stdout_buffer: *[4096]u8, previous_top: lua.StackIndex) !void {
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer);
    const top = lua.getTop(state.luaState);
    if (top == previous_top) return;

    var first = true;
    var index: lua.StackIndex = previous_top + 1;
    while (index <= top) : (index += 1) {
        if (!first) {
            try writer.interface.print(", ", .{});
        }
        first = false;

        const abs_index = lua.absIndex(state.luaState, index);
        if (lua.toDisplayString(state.luaState, abs_index)) |value| {
            try writer.interface.print("{s}", .{value});
        } else {
            try writer.interface.print("{s}", .{lua.typeName(state.luaState, lua.valueType(state.luaState, abs_index))});
        }
    }
    try writer.interface.print("\n", .{});
    try writer.interface.flush();
}

/// Prints the REPL welcome message to stdout.
fn printWelcome(state: *State, stdout_buffer: *[4096]u8, welcome_message: ?[]const u8) !void {
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer);
    if (welcome_message) |message| {
        try writer.interface.print("{s}", .{message});
    } else {
        try writer.interface.print("Lua REPL with Zua\n", .{});
    }
    try writer.interface.flush();
}

/// Prints a single REPL message line with an optional prefix.
fn printMessage(state: *State, stdout_buffer: *[4096]u8, prefix: []const u8, message: []const u8) !void {
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer);
    try writer.interface.print("{s}{s}\n", .{ prefix, message });
    try writer.interface.flush();
}

/// C callback wrapper for linenoise tab completion.
fn completionCallbackC(buffer: [*c]const u8, completions: ?*linenoise.Completions) callconv(.c) void {
    if (completion_callback) |callback| {
        if (completions) |list| {
            callback(std.mem.span(buffer), list);
        }
    }
}

/// C callback wrapper for linenoise syntax highlighting.
///
/// This delegates to the highlight module, which produces the ANSI-colored
/// output for the current source line.
fn highlightCallbackC(buffer: [*c]const u8, len: usize, out_len: [*c]usize) callconv(.c) [*c]const u8 {
    const source = buffer[0..len];
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const out = highlight.process(arena.allocator(), source, active_color_config, active_identifier_hook) orelse return null;
    out_len.* = out.len;
    return out.ptr;
}

test {
    std.testing.refAllDecls(@This());
}
