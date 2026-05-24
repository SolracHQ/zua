//! UpValue handle for Lua CClosure upvalues.
//!
//! A CClosure in Lua has a C function pointer and N upvalues (userdata blocks).
//! This handler wraps a single upvalue userdata together with the C function
//! pointer so the encoder can reconstruct the CClosure from the parts without
//! knowing the inner type at the encode dispatch level.

pub const UpValue = @This();

const std = @import("std");
const lua = @import("../../../lua/lua.zig");
const Handle = @import("../api.zig").Handle;
const State = @import("../../state.zig");
const Marker = @import("../../marker.zig").Marker;

pub const __ZUA_MARKER: std.EnumSet(Marker) = Marker.new(&.{ .docs_ignore, .raw_handle });

state: *State,
handle: Handle,
/// The C function pointer for the closure. Stored at handler-creation time
/// so the encoder can push the CClosure without knowing T.
cfunction: lua.CFunction,

pub fn fromBorrowed(state: *State, index: lua.StackIndex, cfunction: lua.CFunction) UpValue {
    return .{
        .state = state,
        .handle = .{ .borrowed = lua.absIndex(state.luaState, index) },
        .cfunction = cfunction,
    };
}

pub fn fromStack(state: *State, index: lua.StackIndex, cfunction: lua.CFunction) UpValue {
    return .{
        .state = state,
        .handle = .{ .stack_owned = lua.absIndex(state.luaState, index) },
        .cfunction = cfunction,
    };
}

pub fn owned(self: @This()) @This() {
    return .{
        .state = self.state,
        .handle = self.handle.owned(self.state),
        .cfunction = self.cfunction,
    };
}

pub fn takeOwnership(self: @This()) @This() {
    return .{
        .state = self.state,
        .handle = self.handle.takeOwnership(self.state),
        .cfunction = self.cfunction,
    };
}

pub fn release(self: @This()) void {
    self.handle.release(self.state);
}

pub fn get(self: UpValue) ?*anyopaque {
    return switch (self.handle) {
        .borrowed, .stack_owned => |index| lua.toUserdata(self.state.luaState, index),
        .registry_owned => |ref| {
            _ = lua.rawGetI(self.state.luaState, lua.REGISTRY_INDEX, ref);
            const ptr = lua.toUserdata(self.state.luaState, -1);
            lua.pop(self.state.luaState, 1);
            return ptr;
        },
    };
}

test {
    std.testing.refAllDecls(@This());
}
