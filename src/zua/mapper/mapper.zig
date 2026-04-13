//! Module for mapping Zig and Lua Values in both directions.
const Mapper = @This();

const std = @import("std");

const lua = @import("../../lua/lua.zig");
const Context = @import("../state/context.zig");

pub const Decoder = @import("decode.zig");
pub const Encoder = @import("encode.zig");

pub fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

pub fn optionalChild(comptime T: type) type {
    return @typeInfo(T).optional.child;
}

pub fn parseInteger(comptime T: type, ctx: *Context, index: lua.StackIndex) !T {
    if (!lua.isInteger(ctx.state.luaState, index)) try ctx.fail("expected integer");

    const value = lua.toInteger(ctx.state.luaState, index) orelse return ctx.failTyped(T, "expected integer");
    return std.math.cast(T, value) orelse return ctx.failTyped(T, "integer out of range");
}

pub fn parseFloat(comptime T: type, ctx: *Context, index: lua.StackIndex) !T {
    if (!lua.isNumber(ctx.state.luaState, index)) try ctx.fail("expected number");

    const value = lua.toNumber(ctx.state.luaState, index) orelse return ctx.failTyped(T, "expected number");
    return @floatCast(value);
}

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
