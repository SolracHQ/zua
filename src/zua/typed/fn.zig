//! Typed function wrappers for raw Lua functions.
//!
//! `zua.Fn(ins, outs)` provides a statically typed wrapper around a raw Lua
//! `Function` handle. It can be stored in Zig values and passed through the Lua
//! API while preserving the expected argument and return shapes.

const Function = @import("../handlers/function.zig");
const Context = @import("../state/context.zig");
const Mapper = @import("../mapper/mapper.zig");
const Meta = @import("../meta.zig");

/// Typed wrapper over a raw Lua `Function` handle.
///
/// Provides a statically typed callback wrapper that can be stored on Zig values and passed through the Lua API while preserving the expected argument and return shapes. The wrapper implements `ZUA_META` so it can be encoded to and decoded from Lua values using the normal metadata pipeline.
pub fn Fn(comptime ins: anytype, outs: anytype) type {
    return struct {
        /// Metadata used to encode and decode this typed function wrapper.
        pub const ZUA_META = Meta.Table(@This(), .{}).withEncode(Function, encode).withDecode(decode);
        pub const Args = Mapper.Decoder.ParseResult(ins);
        pub const Result = Mapper.Decoder.ParseResult(outs);

        /// Underlying raw Lua function handle.
        function: Function,

        /// Converts the typed wrapper into the raw `Function` handle for Lua.
        ///
        /// This is used by the encoder when a `Fn(ins, outs)` value is returned to
        /// or stored in Lua. It preserves the existing function ownership mode.
        fn encode(_: *Context, self: @This()) Function {
            return self.function;
        }

        /// Decodes a Lua function primitive into the typed wrapper.
        ///
        /// The hook path is intentionally minimal: only actual Lua functions are
        /// accepted, and any other Lua value fails with `expected function`.
        fn decode(ctx: *Context, prim: Mapper.Decoder.Primitive) anyerror!@This() {
            return switch (prim) {
                .function => |f| @This().from(f),
                else => ctx.failTyped(@This(), "expected function"),
            };
        }

        /// Calls the wrapped Lua function with typed arguments and decodes the result.
        ///
        /// The `args` parameter is already parsed by `Mapper.Decoder` and may be a
        /// single value or a tuple. This method forwards the arguments to the raw
        /// function handle and returns the decoded `outs` result.
        ///
        /// Example:
        /// ```zig
        /// fn delegateSum(ctx: *zua.Context, sum: zua.Fn(.{i32, i32}, i32), a: i32, b: i32) !i32 {
        ///     return sum.call(ctx, .{a, b});
        /// }
        /// ```
        pub fn call(self: @This(), ctx: *Context, args: Args) !Result {
            switch (comptime @typeInfo(Args)) {
                .void => {
                    return self.function.call(ctx, .{}, outs);
                },
                .@"struct" => |info| {
                    if (info.is_tuple) {
                        return self.function.call(ctx, args, outs);
                    } else {
                        return self.function.call(ctx, .{args}, outs);
                    }
                },
                else => {
                    return self.function.call(ctx, .{args}, outs);
                },
            }
        }

        /// Constructs a typed wrapper from an existing raw Lua `Function` handle.
        pub fn from(function: Function) @This() {
            return .{ .function = function };
        }

        /// Converts the wrapper into an owned function handle anchored in the Lua registry.
        ///
        /// This is useful when the callback needs to be stored beyond the current Lua
        /// stack frame. The returned wrapper owns the registry reference.
        pub fn takeOwnership(self: @This()) @This() {
            return .{ .function = self.function.takeOwnership() };
        }

        /// Releases the wrapped raw function handle.
        ///
        /// For registry-owned handles this unrefs the function. For stack-owned
        /// handles this removes the function slot from the Lua stack.
        pub fn release(self: @This()) void {
            self.function.release();
        }
    };
}
