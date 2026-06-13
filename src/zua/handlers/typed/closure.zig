//! Typed closure upvalue wrapper.
//!
//! `Closure(T)` is a typed handle around the upvalue userdata of a Lua CClosure whose inner type is `T`. It mirrors
//! `Object(T)` for userdata: you call `.get()` to access the `*T` payload, and the encode path reconstructs the callable
//! closure by pushing the upvalue together with the C function trampoline derived from `T`.
//!
//! Use this as the receiver in a closure callback to pass the closure itself to another Lua function (e.g. a middleware
//! chain) without copying the upvalue on every round-trip.

const std = @import("std");
const lua = @import("../../../lua/lua.zig");
const Shape = @import("../../shape/api.zig");
const Context = @import("../../context.zig");
const State = @import("../../state.zig");
const UpValue = @import("../any/upvalue.zig");
const Primitive = @import("../../mapper/api.zig").Primitive;
const ShapeData = @import("../../shape/shape_data.zig");
const Marker = @import("../../marker.zig").Marker;
const Modifier = @import("../../shape/modifier.zig");
const ObjectGuard = @import("../../mapper/object_guard.zig");

pub fn Closure(comptime T: type) type {
    return struct {
        pub const ZUA_SHAPE = Shape.Table(@This(), .{}, .{})
            .withEncode(UpValue, encode)
            .withDecode(decode);
        pub const __ZUA_MARKER = Marker.closure_wrapper;
        const __ZUA_CLOSURE_TYPE = T;

        handle: UpValue,
        ptr: Modifier.Ignore(*T),

        pub fn encode(_: *Context, self: @This()) !?UpValue {
            return self.handle;
        }

        fn decode(ctx: *Context, prim: Primitive) !?@This() {
            return switch (prim) {
                .userdata => |u| blk: {
                    const raw = u.get() orelse return ctx.fail(?@This(), error.NullValue, "null upvalue", .{});
                    const guard_ptr = try ObjectGuard.ObjectGuard(T).from(ctx, raw);
                    break :blk @This(){
                        .handle = .{
                            .state = ctx.state,
                            .handle = u.handle,
                            .cfunction = ShapeData.getShape(T).trampoline(),
                        },
                        .ptr = .new(guard_ptr),
                    };
                },
                else => ctx.fail(?@This(), error.WrongType, "expected userdata", .{}),
            };
        }

        pub fn get(self: @This()) *T {
            return self.ptr.value;
        }
    };
}
