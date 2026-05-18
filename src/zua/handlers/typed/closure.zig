//! Typed closure upvalue wrapper.
//!
//! `Closure(T)` is a typed handle around the upvalue userdata of a Lua
//! CClosure whose inner type is `T`. It mirrors `Object(T)` for userdata:
//! you call `.get()` to access the `*T` payload, and the encode path
//! reconstructs the callable closure by pushing the upvalue together
//! with the C function trampoline derived from `T`.
//!
//! Use this as the receiver in a closure callback to pass the closure
//! itself to another Lua function (e.g. a middleware chain) without
//! copying the upvalue on every round-trip.

const std = @import("std");
const lua = @import("../../../lua/lua.zig");
const Shape = @import("../../shape/api.zig");
const Context = @import("../../context.zig");
const State = @import("../../state.zig");
const UpValue = @import("../any/upvalue.zig");
const Primitive = @import("../../mapper/api.zig").Primitive;
const ShapeData = @import("../../shape/shape_data.zig");
const Marker = @import("../../marker.zig").Marker;

pub fn Closure(comptime T: type) type {
    return struct {
        pub const ZUA_SHAPE = Shape.Table(@This(), .{}, .{})
            .withEncode(UpValue, encode)
            .withDecode(decode);
        pub const __ZUA_MARKER = Marker.closure_wrapper;
        const __ZUA_CLOSURE_TYPE = T;

        handle: UpValue,

        pub fn encode(_: *Context, self: @This()) !?UpValue {
            return self.handle;
        }

        fn decode(ctx: *Context, prim: Primitive) !?@This() {
            return switch (prim) {
                .userdata => |u| @This(){
                    .handle = .{
                        .state = ctx.state,
                        .handle = u.handle,
                        .cfunction = ShapeData.getShape(T).trampoline(),
                    },
                },
                else => ctx.failTyped(?@This(), "expected userdata"),
            };
        }

        pub fn get(self: @This()) *T {
            const ptr = self.handle.get() orelse @panic("invalid closure upvalue handle");
            return @ptrCast(@alignCast(ptr));
        }
    };
}
