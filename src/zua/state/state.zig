const std = @import("std");
const lua = @import("../../lua/lua.zig");
const Table = @import("../handlers/table.zig").Table;
const Mapper = @import("../mapper/mapper.zig");
const Context = @import("context.zig");
const metatable = @import("../metatable.zig");

const zua_registry_key: [:0]const u8 = "zua_zua";

/// A Fat Wrapper over Lua State that owns the Lua state, allocator, I/O interface, and cached metatables.
/// Is the main component of State API, the only canonical way to access to Lua state and registry, and the main entry point for all operations.
///
/// Create one with `State.init(allocator, io)` and keep it heap-allocated so its pointer remains stable inside callbacks. Call `deinit` to close the state and free memory.
///
/// Use `globals()` and `registry()` to attach tables or functions.
pub const State = @This();

allocator: std.mem.Allocator,
luaState: *lua.State,
// Maps @typeName(T) to a LUA_REGISTRYINDEX ref for the cached metatable.
metatable_cache: std.StringHashMap(c_int),
/// Io interface for basically anything since zif 0.16.0
io: std.Io,

/// Creates a heap-allocated ZuaState instance, opens Lua standard libraries, and stores the pointer in the registry.
/// The returned pointer is stable and safe to capture in callbacks.
pub fn init(allocator: std.mem.Allocator, io: std.Io) !*State {
    const self = try allocator.create(State);
    errdefer allocator.destroy(self);

    const state = try lua.init();
    errdefer lua.deinit(state);

    self.* = .{
        .allocator = allocator,
        .luaState = state,
        .metatable_cache = std.StringHashMap(c_int).init(allocator),
        .io = io,
    };

    lua.openLibs(state);
    lua.pushLightUserdata(state, self);
    lua.setField(state, lua.REGISTRY_INDEX, zua_registry_key);

    return self;
}

/// Closes the Lua state and frees the ZuaState allocation.
pub fn deinit(self: *State) void {
    var it = self.metatable_cache.valueIterator();
    while (it.next()) |ref| {
        lua.unref(self.luaState, lua.REGISTRY_INDEX, ref.*);
    }
    self.metatable_cache.deinit();

    lua.pushNil(self.luaState);
    // this is comment out because I really don't know what to do, self is needed on lua.deinit becaus __gc metamethods might need to access the registry to find the ZuaState pointer, but that also means we can't nil out the registry entry until after lua.deinit runs, and if we wait until after lua.deinit then we can't pop the registry entry at all because the state is already closed. Anyways, I'm freeing the pointer so is in the wors case just a dangling pointer that will never be accessed. In case of weird errors I will revisit this desition.
    // lua.setField(self.state, lua.REGISTRY_INDEX, zua_registry_key);
    lua.deinit(self.luaState);
    self.allocator.destroy(self);
}

/// Pushes the cached metatable for T onto the stack, creating it on first call.
pub fn getOrCreateMetatable(self: *State, comptime T: type) void {
    const key = @typeName(T);

    if (self.metatable_cache.get(key)) |ref| {
        _ = lua.rawGetI(self.luaState, lua.REGISTRY_INDEX, ref);
        return;
    }

    metatable.buildMetatable(self, T);

    lua.pushValue(self.luaState, -1);
    const ref = lua.ref(self.luaState, lua.REGISTRY_INDEX);
    self.metatable_cache.put(key, ref) catch @panic("out of memory storing metatable ref");
}

pub fn globals(self: *State) Table {
    _ = lua.getIndex(self.luaState, lua.REGISTRY_INDEX, lua.RIDX_GLOBALS);
    return Table.fromStack(self, -1);
}

/// Pushes the Lua registry onto the stack and returns an absolute-indexed handle.
/// Use this to store host state via `setLightUserdata("key", &state)`.
pub fn registry(self: *State) Table {
    lua.pushValue(self.luaState, lua.REGISTRY_INDEX);
    return Table.fromStack(self, -1);
}

/// Recovers the owning ZuaState instance from a raw `lua_State` pointer.
/// Called by the callback trampoline to retrieve the ZuaState context.
pub fn fromState(state: *lua.State) ?*State {
    _ = lua.getField(state, lua.REGISTRY_INDEX, zua_registry_key);
    defer lua.pop(state, 1);

    const ptr = lua.toLightUserdata(state, -1);
    return @ptrCast(@alignCast(ptr));
}

test {
    std.testing.refAllDecls(@This());
}
