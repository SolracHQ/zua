const std = @import("std");
const lua = @import("../../lua/lua.zig");
const Table = @import("../handlers/table.zig").Table;
const Mapper = @import("../mapper/mapper.zig");
const Context = @import("context.zig");
const MetaTable = @import("../metatable.zig");

const registry_key_prefix: [:0]const u8 = "zua_zua_";
var zua_registry_key: [:0]const u8 = "zua_zua";

/// A Fat Wrapper over Lua State that owns the Lua state, allocator, I/O interface, and cached metatables.
/// Is the main component of State API, the only canonical way to access Lua state and registry, and the main entry point for all operations.
///
/// Create one with `State.init(allocator, io)` for a fresh Lua state, or `State.libState(L, allocator, io, suffix)`
/// for an existing state received by a shared library loader. Call `deinit` to close the Lua state.
///
/// Use `globals()` and `registry()` to attach tables or functions.
pub const State = @This();

allocator: std.mem.Allocator,
luaState: *lua.State,
// Maps @typeName(T) to a LUA_REGISTRYINDEX ref for the cached metatable.
metatable_cache: std.StringHashMap(c_int),
/// Io interface for basically anything since zif 0.16.0
io: std.Io,

fn stateGc(L: ?*lua.State) callconv(.c) c_int {
    const state = L orelse unreachable;
    const ptr = lua.toUserdata(state, 1) orelse return 0;
    const self: *State = @ptrCast(@alignCast(ptr));
    self.cleanup();
    return 0;
}

fn cleanup(self: *State) void {
    var it = self.metatable_cache.valueIterator();
    while (it.next()) |ref| {
        lua.unref(self.luaState, lua.REGISTRY_INDEX, ref.*);
    }
    self.metatable_cache.deinit();
}

fn makeRegistryKey(comptime suffix: []const u8) [:0]const u8 {
    return std.fmt.comptimePrint("{s}{s}", .{ registry_key_prefix, suffix });
}

/// Creates a Lua-managed ZuaState userdata, opens Lua standard libraries, and stores the pointer in the registry.
/// The returned pointer is stable and safe to capture in callbacks as long as the Lua state remains alive.
pub fn init(allocator: std.mem.Allocator, io: std.Io) !*State {
    const state = try lua.init();
    errdefer lua.deinit(state);

    const self: *State = @ptrCast(@alignCast(lua.newUserdata(state, @sizeOf(State))));
    self.* = .{
        .allocator = allocator,
        .luaState = state,
        .metatable_cache = std.StringHashMap(c_int).init(allocator),
        .io = io,
    };

    lua.openLibs(state);

    lua.createTable(state, 0, 1);
    lua.pushCFunction(state, stateGc);
    lua.setField(state, -2, "__gc");
    _ = lua.setMetatable(state, -2);

    lua.setField(state, lua.REGISTRY_INDEX, zua_registry_key);

    return self;
}

/// Creates or reuses a ZuaState userdata inside an existing Lua state.
/// This is intended for shared libraries and module loaders that receive an
/// existing `lua_State` pointer from `luaopen_*`.
///
/// The returned pointer is stored in the Lua registry under a suffix-specific
/// key derived from `zua_zua_`.
pub fn libState(
    L: *lua.State,
    allocator: std.mem.Allocator,
    io: std.Io,
    comptime suffix: []const u8,
) !*State {
    zua_registry_key = makeRegistryKey(suffix);

    const existing = lua.getField(L, lua.REGISTRY_INDEX, zua_registry_key);
    if (existing != .nil) {
        defer lua.pop(L, 1);
        const ptr = lua.toUserdata(L, -1) orelse @panic("registry value for Zua state is not userdata");
        return @ptrCast(@alignCast(ptr));
    }
    lua.pop(L, 1);

    const self: *State = @ptrCast(@alignCast(lua.newUserdata(L, @sizeOf(State))));
    self.* = .{
        .allocator = allocator,
        .luaState = L,
        .metatable_cache = std.StringHashMap(c_int).init(allocator),
        .io = io,
    };

    lua.createTable(L, 0, 1);
    lua.pushCFunction(L, stateGc);
    lua.setField(L, -2, "__gc");
    _ = lua.setMetatable(L, -2);

    lua.setField(L, lua.REGISTRY_INDEX, zua_registry_key);
    return self;
}

/// Closes the Lua state. Cleanup of Zua-owned runtime state is handled by the
/// `__gc` metamethod on the state userdata when the Lua state is closed.
pub fn deinit(self: *State) void {
    lua.deinit(self.luaState);
}

/// Pushes the cached metatable for T onto the stack, creating it on first call.
pub fn getOrCreateMetatable(self: *State, comptime T: type) void {
    const key = @typeName(T);

    if (self.metatable_cache.get(key)) |ref| {
        _ = lua.rawGetI(self.luaState, lua.REGISTRY_INDEX, ref);
        return;
    }

    MetaTable.buildMetatable(self, T);

    lua.pushValue(self.luaState, -1);
    const ref = lua.ref(self.luaState, lua.REGISTRY_INDEX);
    self.metatable_cache.put(key, ref) catch @panic("out of memory storing metatable ref");
}

/// Returns a borrowed handle to the Lua globals table.
///
/// The returned `Table` points to `LUA_RIDX_GLOBALS` in the registry and is
/// valid as long as the Lua state is alive. Use `addGlobals` to write into it.
///
/// Returns:
/// - Table: A borrowed handle to `_G`.
pub fn globals(self: *State) Table {
    _ = lua.getIndex(self.luaState, lua.REGISTRY_INDEX, lua.RIDX_GLOBALS);
    return Table.fromStack(self, -1);
}
/// Writes the fields from `value` into the existing globals table.
///
/// This is equivalent to `Mapper.Encoder.fillTable` on `state.globals()` and
/// can be called multiple times to register independent subsystems.
pub fn addGlobals(self: *State, ctx: *Context, value: anytype) !void {
    const _globals = self.globals();
    try Mapper.Encoder.fillTable(ctx, _globals, value);
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

    const ptr = lua.toUserdata(state, -1);
    return @ptrCast(@alignCast(ptr));
}

test {
    std.testing.refAllDecls(@This());
}
