//! Executor evaluates Lua chunks in an existing Zua execution context.
//!
//! This module provides a reusable `Executor` type for loading and executing
//! Lua source from a string or file path. It captures optional stack trace
//! behavior and can preserve error messages beyond the call-local `Context`.
const std = @import("std");
const lua = @import("../../lua/lua.zig");
const Mapper = @import("../mapper/mapper.zig");
const Context = @import("../state/context.zig");

pub const Executor = @This();

/// Execution configuration for a Lua chunk.
pub const Config = struct {
    code: union(enum) {
        file: []const u8,
        string: []const u8,
    },
    /// Controls whether a Lua stack traceback is captured and how it is stored.
    stack_trace: enum {
        arena,
        heap,
        no,
    } = .no,
    /// If true, the error message from context is copied into the state allocator
    /// so it survives context disposal.
    /// For Lua errors this means a message that would otherwise be arena-backed
    /// can be preserved beyond the current call.
    take_error_ownership: bool = false,
};

/// Holds the captured stack trace when traceback capture is enabled.
stack_trace: ?[]const u8 = null,

/// Lua-facing error message recorded during execution.
err: ?[]const u8 = null,

/// The Lua error status returned by the protected call.
lua_error_status: ?lua.Error = null,

/// Loads and executes a Lua chunk without returning results.
///
/// This uses the provided `Context` and preserves the Lua stack top across the
/// call. If loading or execution fails, it records a Lua-facing error message
/// on `ctx.err` and returns `error.Failed`.
///
/// Arguments:
/// - ctx: The current call context and allocator.
/// - config: The execution options for the chunk.
///
/// Returns:
/// - !void: `error.Failed` on load or runtime failure.
pub fn execute(self: *Executor, ctx: *Context, config: Config) !void {
    self.stack_trace = null;
    self.err = null;
    const previous_top = lua.getTop(ctx.state.luaState);
    errdefer lua.setTop(ctx.state.luaState, previous_top);

    loadChunk(ctx, config) catch |err| return self.setLuaError(ctx, err, config);
    try self.callLoadedChunk(ctx, 0, config);
}

/// Loads and executes a Lua chunk and decodes returned values into `types`.
///
/// If the chunk fails to load, execute, or decode, `ctx.err` is populated with
/// a printable error message. When `config.take_error_ownership` is enabled,
/// the error message is preserved beyond the current `Context`.
///
/// Arguments:
/// - ctx: The current call context and allocator.
/// - types: The compile-time expected return shape.
/// - config: The execution options for the chunk.
///
/// Returns:
/// - !Mapper.Decoder.ParseResult(types): The decoded values on success.
/// - error.Failed: On Lua or parse failures.
pub fn eval(self: *Executor, ctx: *Context, comptime types: anytype, config: Config) !Mapper.Decoder.ParseResult(types) {
    self.stack_trace = null;
    self.err = null;
    const previous_top = lua.getTop(ctx.state.luaState);
    errdefer lua.setTop(ctx.state.luaState, previous_top);

    loadChunk(ctx, config) catch |err| {
        try self.setLuaError(ctx, err, config);
        return error.Failed;
    };
    try self.callLoadedChunk(ctx, lua.MULT_RETURN, config);

    const parsed = Mapper.Decoder.parseTuple(ctx, previous_top + 1, lua.getTop(ctx.state.luaState) - previous_top, types) catch |err| {
        if (config.take_error_ownership) try self.takeErrorOwnership(ctx);
        return err;
    };

    lua.setTop(ctx.state.luaState, previous_top);
    return parsed;
}

fn loadChunk(ctx: *Context, config: Config) lua.Error!void {
    return switch (config.code) {
        .string => {
            const source = try ctx.heap().dupeZ(u8, config.code.string);
            defer ctx.heap().free(source);
            try lua.loadString(ctx.state.luaState, source);
        },
        .file => {
            const path = try ctx.heap().dupeZ(u8, config.code.file);
            defer ctx.heap().free(path);
            try lua.loadFile(ctx.state.luaState, .{ .path = path });
        },
    };
}

fn callLoadedChunk(self: *Executor, ctx: *Context, num_results: i32, config: Config) !void {
    var errfunc: i32 = 0;
    if (config.stack_trace != .no) {
        lua.pushTracebackFunction(ctx.state.luaState);
        lua.insert(ctx.state.luaState, -2);
        errfunc = lua.absIndex(ctx.state.luaState, -2);
    }

    lua.protectedCall(ctx.state.luaState, 0, num_results, errfunc) catch |err| {
        return self.setLuaError(ctx, err, config);
    };
}

fn setLuaError(self: *Executor, ctx: *Context, status: lua.Error, config: Config) !void {
    const raw_message = lua.toDisplayString(ctx.state.luaState, -1) orelse "unknown error";
    const message = try allocateErrorMessage(ctx, raw_message, config);
    ctx.err = message;
    self.lua_error_status = status;
    if (config.take_error_ownership or config.stack_trace == .heap) {
        self.err = message;
        if (config.stack_trace != .no) self.stack_trace = message;
    } else {
        self.err = null;
        self.stack_trace = null;
    }
    return error.Failed;
}

fn allocateErrorMessage(ctx: *Context, raw_message: []const u8, config: Config) ![]const u8 {
    const alloc = if (config.take_error_ownership or config.stack_trace == .heap)
        ctx.heap()
    else
        ctx.arena();

    return alloc.dupe(u8, raw_message);
}

fn takeErrorOwnership(self: *Executor, ctx: *Context) !void {
    if (ctx.err) |msg| {
        const owned = try ctx.heap().dupe(u8, msg);
        self.err = owned;
    }
}

test {
    std.testing.refAllDecls(@This());
}
