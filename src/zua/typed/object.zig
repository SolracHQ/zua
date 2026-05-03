//! Typed object userdata wrappers for Lua full userdata values.
//!
//! `Object(T)` is a lightweight typed wrapper around the raw `handlers.Userdata`
//! handle. It preserves Lua stack and registry ownership semantics while
//! exposing a typed accessor for values stored in full userdata.
const std = @import("std");
const lua = @import("../../lua/lua.zig");
const Context = @import("../state/context.zig");
const Meta = @import("../meta/meta.zig");
const MetaTable = @import("../metatable.zig");
const State = @import("../state/state.zig");
const UserData = @import("../handlers/userdata.zig");
const Primitive = @import("../mapper/mapper.zig").Decoder.Primitive;

/// Typed object handle for Lua full userdata values.
///
/// `Object(T)` provides a typed wrapper around the raw `handlers.Userdata`
/// handler. It decodes Lua `userdata` values into a typed handle and exposes a
/// typed `.get()` method to access the embedded `T` payload.
pub fn Object(comptime T: type) type {
    comptime {
        if (@typeInfo(T) == .@"fn") {
            @compileError("Object(T) cannot wrap function types");
        }
        const strategy = Meta.strategyOf(T);
        if (strategy != .object) {
            @compileError(@typeName(T) ++ " must use object strategy to be wrapped by Object(T)");
        }
    }

    return struct {
        pub const ZUA_META = Meta.Table(@This(), .{}, .{}).withDecode(decode).withEncode(UserData, encode);
        pub const __ZUA_USERDATA_TYPE = T;

        /// Underlying raw userdata handle.
        handle: UserData,

        /// Converts this typed object wrapper into the underlying raw userdata.
        ///
        /// This is used by the metadata pipeline when an `Object(T)` value is
        /// returned to or stored in Lua.
        pub fn encode(_: *Context, self: @This()) !?UserData {
            return self.handle;
        }

        /// Decodes a Lua userdata primitive into the typed object wrapper.
        ///
        /// Only raw Lua userdata values are accepted.
        fn decode(ctx: *Context, handle: Primitive) !?@This() {
            return switch (handle) {
                .userdata => |p| @This().from(p),
                else => return ctx.failTyped(?@This(), "expected userdata"),
            };
        }

        /// Constructs a typed object wrapper from an existing raw userdata handle.
        pub fn from(handle: UserData) @This() {
            return .{ .handle = handle };
        }

        /// Allocates a new typed userdata object and returns a typed handle.
        ///
        /// The object payload is copied into the Lua userdata block and the
        /// associated metatable is attached.
        pub fn create(state: *State, value: T) @This() {
            const ptr: *T = @ptrCast(@alignCast(lua.newUserdata(state.luaState, @sizeOf(T))));
            ptr.* = value;
            MetaTable.attachMetatable(state, T);
            return .{ .handle = UserData.fromStack(state, -1) };
        }

        /// Returns the typed payload pointer stored inside the userdata.
        pub fn get(self: @This()) *T {
            const ptr = self.handle.get() orelse @panic("invalid userdata handle");
            return @ptrCast(@alignCast(ptr));
        }

        /// Converts the underlying raw userdata handle to a registry-owned handle.
        ///
        /// This is useful when the object needs to survive beyond the current Lua
        /// stack frame.
        pub fn takeOwnership(self: @This()) @This() {
            return .{ .handle = self.handle.takeOwnership() };
        }

        /// Creates a second independent registry-owned handle to the same Lua userdata.
        pub fn owned(self: @This()) @This() {
            return .{ .handle = self.handle.owned() };
        }

        /// Releases the wrapped raw userdata handle.
        pub fn release(self: @This()) void {
            self.handle.release();
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
