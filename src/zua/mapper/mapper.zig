//! Module for mapping Zig and Lua Values in both directions.
const Mapper = @This();

const std = @import("std");

const lua = @import("../../lua/lua.zig");
const Context = @import("../state/context.zig");
const Handlers = @import("../handlers/handlers.zig");

pub const Decoder = @import("decode.zig");
pub const Encoder = @import("encode.zig");

/// Decoded Lua primitive value, used by custom decode hooks.
///
/// Represents a Lua value after type-checking but before type-specific decoding.
/// The `table` variant holds a borrowed handle valid for the duration of the
/// decode hook execution (the value remains on the stack).
pub const Primitive =
    union(enum) {
        /// Represents a Lua `nil` or absent value.
        nil,
        boolean: bool,
        integer: i64,
        float: f64,
        string: []const u8,
        table: Handlers.Table,
        function: Handlers.Function,
        light_userdata: *anyopaque,
        userdata: Handlers.Userdata,
    };

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
