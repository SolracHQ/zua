//! Context is a short-lived call-local object used during Zua function evaluation.
//! It wraps shared `State`, owns an arena for temporary allocations, and captures
//! runtime error messages in a form Lua can raise. `Context` owns the callback
//! lifetime resources for a single Zua invocation and exposes helpers for
//! allocation and failure propagation.
pub const Context = @This();

const std = @import("std");

pub const State = @import("state.zig");

/// Shared global Zua `State` pointer used by the current callback. This pointer is borrowed for the duration of the invocation and is not owned by `Context`.
state: *State,
/// Arena allocator for temporary allocations made during the current ZuaFn invocation.
/// It is freed by `deinit` and should only be used for transient values that do not
/// need to survive after the callback returns.
///
/// The public API exposes this through `ctx.arena()`; the backing field is named
/// `__arena` to avoid conflicts with a user-facing property.
__arena: std.heap.ArenaAllocator,
/// Optional Lua-facing error message recorded when a runtime failure occurs.
/// This may point to a static string or an arena allocation; `Context` never frees the message directly.
err: ?[]const u8 = null,

/// Creates a call-local `Context` for a single ZuaFn invocation.
///
/// This allocates an arena from `z.allocator`, captures the shared `State`, and clears the error state.
/// The returned `Context` is intended for one callback frame and must be deinitialized when the call completes.
///
/// Arguments:
/// - z: A pointer to the global `State` used by the current Lua execution.
///
/// Returns:
/// - Context: A new call-local context with an initialized arena and cleared
///   error state.
///
/// Example:
/// ```zig
/// var ctx = Context.init(z);
/// defer ctx.deinit();
/// ```
pub fn init(z: *State) Context {
    const __arena = std.heap.ArenaAllocator.init(z.allocator);
    return Context{
        .state = z,
        .__arena = __arena,
    };
}

/// Frees the arena owned by this `Context` and makes the object unusable.
///
/// Use this as the final cleanup step for a call-local invocation frame.
/// After calling `deinit`, the context allocator and any arena allocations become invalid.
///
/// Example:
/// ```zig
/// var ctx = Context.init(z);
/// defer ctx.deinit();
/// // use ctx inside the callback
/// ```
pub fn deinit(self: *Context) void {
    self.__arena.deinit();
}

/// Returns the temporary arena allocator attached to this `Context`.
///
/// This allocator is intended for transient allocations that only need to live until the current callback returns.
/// Use it for error strings, scratch buffers, and temporary helper data.
///
/// Returns:
/// - std.mem.Allocator: An allocator backed by the call-local arena.
///
/// For allocations that must outlive the callback, use `ctx.heap()` instead.
pub fn arena(self: *Context) std.mem.Allocator {
    return self.__arena.allocator();
}

/// Returns the persistent heap allocator associated with the shared `State`.
///
/// Use this allocator for values that must outlive the current Lua call,
/// including object fields, stored callbacks, and owned resources.
/// The caller is responsible for freeing allocations made from this allocator.
///
/// Returns:
/// - std.mem.Allocator: The state allocator.
pub fn heap(self: *Context) std.mem.Allocator {
    return self.state.allocator;
}

/// Records a Lua-facing error message on the `Context` and returns `error.Failed`.
///
/// The message is stored in `ctx.err` so the trampoline can raise it to Lua after the invocation completes.
///
/// Arguments:
/// - msg: The error message to record. It must remain valid until the current
///   invocation completes.
///
/// Returns:
/// - !void: Always returns `error.Failed`.
///
/// Example:
/// ```zig
/// allocOp() catch {
///     try ctx.fail("allocation failed on important call");
/// }
/// ```
pub fn fail(self: *Context, msg: []const u8) !void {
    self.err = msg;
    return error.Failed;
}

/// Records a Lua-facing error message on the `Context` and returns `error.Failed`
/// as a typed result.
///
/// Use this in functions that return a value on success so the failure path
/// still carries the correct `!T` signature.
///
/// Arguments:
/// - T: The expected success type for the caller.
/// - msg: The error message to record.
///
/// Returns:
/// - !T: Always returns `error.Failed`.
///
/// Example:
/// ```zig
/// const str = getOptional() orelse return ctx.failTyped([]const u8, "expected value not found");
/// ```
pub fn failTyped(self: *Context, comptime T: type, msg: []const u8) !T {
    self.err = msg;
    return error.Failed;
}

/// Formats an error message into the context arena and returns `error.Failed`.
///
/// Use this when the error message requires runtime interpolation and the callback does not return a success value.
///
/// Arguments:
/// - fmt: The format string.
/// - args: The values to interpolate into the formatted message.
///
/// Returns:
/// - !void: Always returns `error.Failed`.
///
/// Example:
/// ```zig
/// allocOp() catch |err| {
///     try ctx.failWithFmt("allocation failed: {s}", .{err});
/// }
/// ```
pub fn failWithFmt(self: *Context, comptime fmt: []const u8, args: anytype) !void {
    const msg = std.fmt.allocPrint(self.arena(), fmt, args) catch
        return error.Failed;
    self.err = msg;
    return error.Failed;
}

/// Formats a typed error message into the context arena and returns `error.Failed`.
///
/// Use this in functions that return a value and need a formatted failure string.
///
/// Arguments:
/// - T: The expected success type for the caller.
/// - fmt: The format string.
/// - args: The values to interpolate.
///
/// Returns:
/// - !T: Always returns `error.Failed`.
///
/// Example:
/// ```zig
/// const value = parseInput() orelse return ctx.failWithFmtTyped(i32, "invalid input: {s}", .{err});
/// ```
pub fn failWithFmtTyped(self: *Context, comptime T: type, comptime fmt: []const u8, args: anytype) !T {
    const msg = std.fmt.allocPrint(self.arena(), fmt, args) catch
        return error.Failed;
    self.err = msg;
    return error.Failed;
}
