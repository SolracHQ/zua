//! Raw userdata handle for Lua full userdata values.
//!
//! This handler manages borrowed stack references, stack-owned userdata
//! values, and registry-owned references for raw Lua userdata. It is the
//! low-level primitive used by the typed `Object(T)` wrapper.

pub const Userdata = @This();

const HandleOwnership = @import("handlers.zig").HandleOwnership;
const lua = @import("../../lua/lua.zig");
const State = @import("../state/state.zig");

state: *State,
handle: union(HandleOwnership) {
    borrowed: lua.StackIndex,
    stack_owned: lua.StackIndex,
    registry_owned: c_int,
},

/// Creates a borrowed raw userdata handle for a stack slot owned by another API operation.
///
/// The borrowed handle does not own the stack slot and must not be released.
pub fn fromBorrowed(state: *State, index: lua.StackIndex) Userdata {
    return .{
        .state = state,
        .handle = .{ .borrowed = lua.absIndex(state.luaState, index) },
    };
}

/// Creates a stack-owned raw userdata handle that must be released via `release()`.
///
/// The returned handle owns the referenced stack slot and is suitable for values
/// created by API helpers that push userdata onto the stack.
pub fn fromStack(state: *State, index: lua.StackIndex) Userdata {
    return .{
        .state = state,
        .handle = .{ .stack_owned = lua.absIndex(state.luaState, index) },
    };
}

/// Allocates a new full userdata block of `size` bytes and returns a stack-owned handle.
///
/// The caller is responsible for releasing the returned handle or leaving it on
/// the stack until Lua owns it.
pub fn create(state: *State, size: usize) Userdata {
    _ = lua.newUserdata(state.luaState, size);
    return Userdata.fromStack(state, -1);
}

/// Anchors this userdata in the Lua registry for persistent storage.
///
/// The returned handle owns the registry reference and may be released with
/// `release()` when it is no longer needed.
pub fn takeOwnership(self: @This()) @This() {
    const index = switch (self.handle) {
        inline else => |idx| idx,
    };

    lua.pushValue(self.state.luaState, index);
    const ref = lua.ref(self.state.luaState, lua.REGISTRY_INDEX);

    return .{
        .state = self.state,
        .handle = .{ .registry_owned = ref },
    };
}

/// Releases this userdata from the stack or registry.
///
/// Borrowed handles are a no-op. Stack-owned handles remove the slot from the
/// Lua stack. Registry-owned handles unref the registry reference.
pub fn release(self: @This()) void {
    switch (self.handle) {
        .borrowed => {},
        .stack_owned => |index| lua.remove(self.state.luaState, index),
        .registry_owned => |ref| lua.unref(self.state.luaState, lua.REGISTRY_INDEX, ref),
    }
}

/// Returns the raw userdata pointer stored inside this handle.
///
/// Returns `null` if the Lua value is no longer available. Registry-owned
/// handles temporarily push the referenced value onto the stack while reading
/// it.
pub fn get(self: Userdata) ?*anyopaque {
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
