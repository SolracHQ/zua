//! Typed object userdata wrappers for Lua full userdata values.
//!
//! `Object(T)` is a lightweight typed wrapper around the raw `handlers.Userdata` handle. It preserves Lua stack and
//! registry ownership semantics while exposing a typed accessor for values stored in full userdata.

const std = @import("std");
const lua = @import("../../../lua/lua.zig");
const Context = @import("../../context.zig");
const Shape = @import("../../shape/api.zig");
const ShapeData = @import("../../shape/shape_data.zig");
const MetaTable = @import("../../metatable/api.zig");
const State = @import("../../state.zig");
const UserData = @import("../any/userdata.zig");
const Primitive = @import("../../mapper/api.zig").Primitive;
const ObjectGuard = @import("../../mapper/object_guard.zig");
const Modifier = @import("../../shape/modifier.zig");
const Marker = @import("../../marker.zig").Marker;

/// Typed object handle for Lua full userdata values.
///
/// `Object(T)` provides a typed wrapper around the raw `handlers.Userdata` handler. It decodes Lua `userdata` values into a
/// typed handle and exposes a typed `.get()` method to access the embedded `T` payload.
pub fn Object(comptime T: type) type {
    if (comptime @typeInfo(T) == .@"fn") {
        @compileError("Object(T) cannot wrap function types");
    }

    return struct {
        pub const ZUA_SHAPE = Shape.Table(@This(), .{}, .{}).withDecode(decode).withEncode(UserData, encode);
        pub const __ZUA_MARKER = Marker.userdata_wrapper;
        const UserdataType = T;

        /// Underlying raw userdata handle for ownership semantics.
        handle: UserData,
        /// Cached typed pointer into the Lua userdata block.
        ptr: Modifier.Ignore(*T),

        /// Converts this typed object wrapper into the underlying raw userdata.
        pub fn encode(_: *Context, self: @This()) !?UserData {
            return self.handle;
        }

        /// Decodes a Lua userdata primitive into the typed object wrapper.
        fn decode(ctx: *Context, handle: Primitive) !?@This() {
            return switch (handle) {
                .userdata => |p| try @This().from(ctx, p),
                else => return ctx.fail(?@This(), error.WrongType, "expected userdata", .{}),
            };
        }

        /// Constructs a typed wrapper from a raw handle, verifying the guard.
        pub fn from(ctx: *Context, handle: UserData) !@This() {
            const raw = handle.get() orelse return ctx.fail(@This(), error.TypeMismatch, "null userdata handle", .{});
            const guard_ptr = try ObjectGuard.ObjectGuard(T).from(ctx, raw);
            return .{ .handle = handle, .ptr = .new(guard_ptr) };
        }

        /// Allocates a new typed userdata object and returns a typed handle.
        pub fn create(state: *State, value: T) @This() {
            if (comptime ShapeData.strategyOf(T) != .object)
                @compileError(@typeName(T) ++ " must use object strategy to be wrapped by Object(T)");
            const guard_ptr = ObjectGuard.ObjectGuard(T).push(state.luaState, value);
            MetaTable.attachMetatable(state, T);
            return .{ .handle = UserData.fromStack(state, -1), .ptr = .new(&guard_ptr.value) };
        }

        /// Returns the typed payload pointer stored inside the userdata.
        pub fn get(self: @This()) *T {
            return self.ptr.value;
        }

        /// Converts the underlying raw userdata handle to a registry-owned handle.
        pub fn takeOwnership(self: @This()) @This() {
            return .{ .handle = self.handle.takeOwnership(), .ptr = self.ptr };
        }

        /// Creates a second independent registry-owned handle to the same Lua userdata.
        pub fn owned(self: @This()) @This() {
            return .{ .handle = self.handle.owned(), .ptr = self.ptr };
        }

        /// Releases the wrapped raw userdata handle.
        pub fn release(self: @This()) void {
            self.handle.release();
        }
    };
}

/// Returns the inner type `T` if `Wrapper` is an `Object(T)`, otherwise `null`.
pub fn userdataInnerType(comptime Wrapper: type) ?type {
    if (comptime Marker.isUserdataWrapper(Wrapper)) return Wrapper.UserdataType;
    return null;
}

test {
    std.testing.refAllDecls(@This());
}
