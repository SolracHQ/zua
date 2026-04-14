//! Typed function wrappers for raw Lua functions.
//!
//! `zua.Fn(ins, outs)` provides a statically typed wrapper around a raw Lua
//! `Function` handle. It can be stored in Zig values and passed through the Lua
//! API while preserving the expected argument and return shapes.

const Function = @import("../handlers/function.zig");
const ZuaFn = @import("../functions/zua_fn.zig");
const Context = @import("../state/context.zig");
const Mapper = @import("../mapper/mapper.zig");
const Meta = @import("../meta.zig");

const std = @import("std");

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

        /// Creates a typed wrapper from a pushable Lua callback value.
        ///
        /// This convenience helper accepts existing raw function handles or
        /// typed callback wrappers such as `zua.ZuaFn` and returns a typed
        /// `Fn(ins, outs)` handle for use in Zig values.
        pub fn create(ctx: *Context, callback: anytype) @This() {
            comptime {
                const callback_type = @TypeOf(callback);
                if (@typeInfo(callback_type) == .@"fn" or
                    (@typeInfo(callback_type) == .@"struct" and @hasDecl(callback_type, "__IsZuaFn")))
                {
                    checkCallbackSignature(callback, ins, outs);
                }
            }
            Mapper.Encoder.pushValue(ctx, callback);
            return .{ .function = Function.fromStack(ctx.state, -1) };
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

fn callbackWrapperType(comptime callback: anytype) type {
    const callback_type = @TypeOf(callback);
    if (comptime @typeInfo(callback_type) == .@"fn") {
        return @TypeOf(ZuaFn.new(callback, .{}));
    }
    if (comptime @typeInfo(callback_type) == .@"struct" and @hasDecl(callback_type, "__IsZuaFn")) {
        return callback_type;
    }
    @compileError("Fn.create expects a Zig function or a ZuaFn wrapper for signature validation");
}

fn typeElementCount(comptime T: anytype) usize {
    const Ty = @TypeOf(T);
    if (Ty == type) {
        const ti = @typeInfo(T);
        return if (ti == .void) 0 else if (ti == .@"struct" and ti.@"struct".is_tuple) T.len else 1;
    }
    return T.len;
}

fn typeElementAt(comptime T: anytype, comptime index: usize) type {
    const Ty = @TypeOf(T);
    if (Ty == type) {
        const ti = @typeInfo(T);
        if (ti == .@"struct" and ti.@"struct".is_tuple) return T[index];
        if (index == 0) return T;
        @compileError("type index out of range");
    }
    return T[index];
}

fn checkCallbackSignature(comptime callback: anytype, comptime ins: anytype, comptime outs: anytype) void {
    const wrapper_type = callbackWrapperType(callback);
    const actual_args = wrapper_type.decodedParameterTypes();
    const expected_args = ins;
    const actual_count = typeElementCount(actual_args);
    const expected_count = typeElementCount(expected_args);
    if (comptime actual_count != expected_count) @compileError("Fn.create: callback argument count mismatch: expected " ++ @typeName(expected_count) ++ " args, got " ++ @typeName(actual_count));
    inline for (0..actual_count) |i| {
        const actual = typeElementAt(actual_args, i);
        const expected = typeElementAt(expected_args, i);
        if (comptime actual != expected) @compileError("Fn.create: callback argument #" ++ std.fmt.comptimePrint("{d}", .{i}) ++
            " expected " ++ @typeName(expected) ++
            ", got " ++ @typeName(actual));
    }

    const actual_return = wrapper_type.__ZuaFnReturnType;
    const expected_return = outs;
    const actual_return_count = typeElementCount(actual_return);
    const expected_return_count = typeElementCount(expected_return);
    if (comptime actual_return_count != expected_return_count) @compileError("Fn.create: callback return count mismatch: expected " ++ @typeName(expected_return_count) ++ " return values, got " ++ @typeName(actual_return_count));
    inline for (0..actual_return_count) |i| {
        const actual = typeElementAt(actual_return, i);
        const expected = typeElementAt(expected_return, i);
        if (comptime actual != expected) @compileError("Fn.create: callback return #" ++ std.fmt.comptimePrint("{d}", .{i}) ++
            " expected " ++ @typeName(expected) ++
            ", got " ++ @typeName(actual));
    }
}
