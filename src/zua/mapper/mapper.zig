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
        string: [:0]const u8,
        table: Handlers.Table,
        function: Handlers.Function,
        light_userdata: *anyopaque,
        userdata: Handlers.Userdata,

        /// Decodes this primitive into a Zig value of type `T`.
        ///
        /// Delegates to `Decoder.decodeValue`, which performs type dispatch
        /// using `T`'s `ZUA_META` strategy. The returned value is owned by the
        /// caller.
        ///
        /// Arguments:
        /// - ctx: Call-local context for allocation and error reporting.
        /// - T: The target Zig type to decode into.
        ///
        /// Returns:
        /// - T: The decoded value, or an error if decoding fails.
        pub fn decode(self: Primitive, ctx: *Context, comptime T: type) !T {
            return Decoder.decodeValue(ctx, self, T);
        }
    };

/// Returns whether `T` is an optional type (`?U`).
pub fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

/// Returns the child type of an optional, i.e. `U` for `?U`.
///
/// Asserts at compile time that `T` is indeed an optional type.
pub fn optionalChild(comptime T: type) type {
    return @typeInfo(T).optional.child;
}

/// Reads a Lua integer at `index` and casts it to `T`.
///
/// Fails with a typed error if the value is not an integer or is out of range
/// for `T`. Supports signed and unsigned integer target types.
///
/// Arguments:
/// - T: The target integer type (e.g. `i32`, `u64`).
/// - ctx: Call-local context for error reporting.
/// - index: Lua stack index to read from.
///
/// Returns:
/// - T: The cast integer value.
pub fn parseInteger(comptime T: type, ctx: *Context, index: lua.StackIndex) !T {
    if (!lua.isInteger(ctx.state.luaState, index)) try ctx.fail("expected integer");

    const value = lua.toInteger(ctx.state.luaState, index) orelse return ctx.failTyped(T, "expected integer");
    return std.math.cast(T, value) orelse return ctx.failTyped(T, "integer out of range");
}

/// Reads a Lua number at `index` and casts it to `T`.
///
/// Fails if the value is not a number. Uses `@floatCast` which clips to the
/// target type's range at runtime.
///
/// Arguments:
/// - T: The target float type (e.g. `f32`, `f64`).
/// - ctx: Call-local context for error reporting.
/// - index: Lua stack index to read from.
///
/// Returns:
/// - T: The cast floating-point value.
pub fn parseFloat(comptime T: type, ctx: *Context, index: lua.StackIndex) !T {
    if (!lua.isNumber(ctx.state.luaState, index)) try ctx.fail("expected number");

    const value = lua.toNumber(ctx.state.luaState, index) orelse return ctx.failTyped(T, "expected number");
    return @floatCast(value);
}

/// Returns whether `T` is a string-like type that Lua treats as a string.
///
/// Matches `[]const u8`, `[:0]const u8`, and pointer-to-array-of-u8 patterns.
/// Non-const slices are excluded because Lua strings are immutable.
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

test {
    std.testing.refAllDecls(@This());
}
