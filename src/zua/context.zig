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
/// Arena allocator for temporary allocations made during the current wrapped callback invocation.
/// It is freed by `deinit` and should only be used for transient values that do not
/// need to survive after the callback returns.
///
/// The public API exposes this through `ctx.arena()`; the backing field is named
/// `__arena` to avoid conflicts with a user-facing property.
__arena: std.heap.ArenaAllocator,
/// Optional Lua-facing error message recorded when a runtime failure occurs.
/// This may point to a static string or an arena allocation; `Context` never frees the message directly.
err: ?[]const u8 = null,

/// Creates a call-local `Context` for a single wrapped callback invocation.
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

/// Matches a Zig error with a Lua exception message.
///
/// The message is stored in `ctx.err` for Lua's error handling. The Zig
/// error value preserves explicit control so callers can catch specific
/// errors (`error.WrongType`) or `try` forward just like any other Zig
/// error.
///
/// Arguments:
/// - T: The success type for the `!T` return signature.
/// - err: The Zig error to return (e.g. `error.WrongType`).
/// - fmt: The format string to allocate into the context arena.
/// - args: The values to interpolate.
///
/// Returns:
/// - !T: Returns `err`.
///
/// Example:
/// ```zig
/// const value = getOptional() orelse return ctx.fail(?[]const u8, error.WrongType, "expected string, got {s}", .{@tagName(prim)});
/// ```
pub fn fail(self: *Context, comptime T: type, err: anyerror, comptime fmt: []const u8, args: anytype) !T {
    const msg = try std.fmt.allocPrint(self.arena(), fmt, args);
    self.err = msg;
    return err;
}

test {
    std.testing.refAllDecls(@This());
}
