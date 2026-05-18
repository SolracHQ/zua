//! Encodes Zig values into Lua and decodes Lua values back into Zig.
//! This is the central translation layer. `Encoder.push` converts a Zig
//! value to the Lua stack, `Decoder.pop` reads it back. The translation
//! strategy for each type comes from its `ZUA_SHAPE` metadata.
const Mapper = @This();

const std = @import("std");

const lua = @import("../../lua/lua.zig");
const Context = @import("../context.zig");
const Handlers = @import("../handlers/api.zig");

pub const Decoder = @import("decode/api.zig");
pub const Encoder = @import("encode/api.zig");

/// Lua primitive type tag. Mirrors the `Primitive` union variants without
/// carrying any payload. Useful for error reporting and type dispatch.
pub const PrimitiveTag = enum {
    nil,
    boolean,
    integer,
    float,
    string,
    table,
    function,
    light_userdata,
    userdata,
    handle,
};

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
    table: Handlers.Any.Table,
    function: Handlers.Any.Function,
    light_userdata: *anyopaque,
    userdata: Handlers.Any.Userdata,
    /// Generic handle for Lua values not covered by specific variants (e.g. threads).
    handle: Handlers.Handle,

    /// Returns the `PrimitiveTag` for this primitive, discarding the payload.
    pub fn tag(self: Primitive) PrimitiveTag {
        return switch (self) {
            .nil => .nil,
            .boolean => .boolean,
            .integer => .integer,
            .float => .float,
            .string => .string,
            .table => .table,
            .function => .function,
            .light_userdata => .light_userdata,
            .userdata => .userdata,
            .handle => .handle,
        };
    }

    /// Decodes this primitive into a Zig value of type `T`.
    ///
    /// Delegates to `Decoder.decodeValue`, which performs type dispatch
    /// using `T`'s `ZUA_SHAPE` strategy. The returned value is owned by the
    /// caller.
    ///
    /// Arguments:
    /// - ctx: Call-local context for allocation and error reporting.
    /// - T: The target Zig type to decode into.
    ///
    /// Returns:
    /// - T: The decoded value, or an error if decoding fails.
    pub fn decode(self: Primitive, ctx: *Context, comptime T: type) !T {
        return Decoder.decode(ctx, self, T);
    }
};

/// Internal helpers exposed for users who need them.
pub const Internals = @import("internals.zig");

/// Variadic Lua arguments captured as a slice of primitives.
///
/// Declare `VarArgs` as the last parameter of a callback to receive all Lua
/// arguments that were not matched by preceding parameters. The slice is
/// allocated from the context arena and is valid for the duration of the call.
///
/// Example:
/// ```zig
/// fn log(prefix: []const u8, rest: zua.VarArgs) void {
///     for (rest.args) |arg| { /* inspect each arg */ }
/// }
/// ```
pub const VarArgs = struct {
    args: []Primitive,
};

test {
    std.testing.refAllDecls(@This());
}
