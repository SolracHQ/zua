//! Tagged envelope for userdata type safety.
//!
//! Object and closure userdata carry a hash of `@typeName(T)` alongside
//! the payload. On decode the hash is verified, turning UB into a type
//! error.

const std = @import("std");
const lua = @import("../../lua/lua.zig");
const Context = @import("../context.zig");

/// Type-checked userdata envelope carrying a name hash, a name string
/// for error messages, and the payload `T`.
pub fn ObjectGuard(comptime T: type) type {
    return struct {
        name_hash: u64,
        value: T,

        /// Reads the guard from a raw userdata pointer and returns the
        /// inner value pointer, or fails with `error.TypeMismatch` if the
        /// hash does not match `@typeName(T)`.
        pub fn from(ctx: *Context, handle: *anyopaque) !*T {
            const guard_ptr: *@This() = @ptrCast(@alignCast(handle));
            if (guard_ptr.name_hash != comptime hashOf(T))
                return ctx.fail(*T, error.TypeMismatch, "expected userdata of type {s}, got a different type", .{@typeName(T)});
            return &guard_ptr.value;
        }

        /// Allocates a new userdata block, writes the guard envelope,
        /// and returns a pointer to it so callers can stash `&guard.value`.
        pub fn push(state: *lua.State, value: T) *@This() {
            const ptr: *@This() = @ptrCast(@alignCast(lua.newUserdata(state, @sizeOf(@This()))));
            ptr.* = .{ .name_hash = comptime hashOf(T), .value = value };
            return ptr;
        }
    };
}

/// Comptime hash of `@typeName(T)` used to tag userdata blocks.
pub fn hashOf(comptime T: type) u64 {
    return comptime std.hash.Wyhash.hash(0, @typeName(T));
}
