//! Shared helpers used by both the encoder and decoder pipelines.
//! These are not part of the public API. You can use them if you need
//! to, but they may change without notice.

const std = @import("std");
const lua = @import("../../lua/lua.zig");
const Context = @import("../context.zig");

/// Returns true when T is an optional type (`?U`).
pub fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

/// Returns the child type of an optional. Only valid when `isOptional(T)` is true.
pub fn optionalChild(comptime T: type) type {
    return @typeInfo(T).optional.child;
}

/// Reads a Lua integer from the stack at `index` and casts it to `T`.
/// Fails if the value is not an integer or is out of range for T.
pub fn parseInteger(comptime T: type, ctx: *Context, index: lua.StackIndex) !T {
    if (!lua.isInteger(ctx.state.luaState, index)) try ctx.fail("expected integer");
    const value = lua.toInteger(ctx.state.luaState, index) orelse return ctx.failTyped(T, "expected integer");
    return std.math.cast(T, value) orelse return ctx.failTyped(T, "integer out of range");
}

/// Reads a Lua number from the stack at `index` and casts it to `T`.
/// Fails if the value is not a number.
pub fn parseFloat(comptime T: type, ctx: *Context, index: lua.StackIndex) !T {
    if (!lua.isNumber(ctx.state.luaState, index)) try ctx.fail("expected number");
    const value = lua.toNumber(ctx.state.luaState, index) orelse return ctx.failTyped(T, "expected number");
    return @floatCast(value);
}

/// Returns true when T is a Zig string type: `[]const u8`, `[:0]const u8`,
/// or a pointer to a fixed-size byte array (`*const [N]u8`).
pub fn isStringValueType(comptime T: type) bool {
    if (T == []const u8 or T == [:0]const u8) return true;
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => @typeInfo(pointer.child) == .array and @typeInfo(@typeInfo(pointer.child).array.child) == .int,
            .slice => pointer.child == u8 and pointer.is_const,
            else => false,
        },
        else => false,
    };
}
