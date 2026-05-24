//! Fat wrapper over a Lua VM instance. Owns the `lua_State`, allocator,
//! I/O interface, and metatable cache. Lives as long as the Lua state
//! lives, stored as Lua userdata with `__gc` for automatic cleanup.
//!
//! Create one with `init` for a fresh Lua environment or `libState` when
//! you receive an existing `lua_State*` from a host that already has one.
//! The pointer returned by either path is stable and safe to capture in
//! callbacks. Recover it from a raw `lua_State*` with `fromState`.

const std = @import("std");
const builtin = @import("builtin");
const lua = @import("../lua/lua.zig");
const Table = @import("handlers/any/table.zig").Table;
const Mapper = @import("mapper/api.zig");
const Context = @import("context.zig");
const MetaTable = @import("metatable.zig");

const registry_key_prefix: [:0]const u8 = "zua_zua_";
var zua_registry_key: [:0]const u8 = "zua_zua";

const SavedTop = struct {
    top: i32,
    trace: if (builtin.mode == .Debug) struct { frames: [8]usize, count: usize } else void,
};

/// Stable pointer, safe to capture in callbacks. Valid until `deinit` is called.
pub const State = @This();

allocator: std.mem.Allocator,
luaState: *lua.State,
/// Each metatable is keyed by `@typeName(T)` so that types with the same
/// name in different modules share a cached metatable. References are
/// stored in the Lua registry and unrefed on cleanup.
metatable_cache: std.StringHashMap(c_int),
/// Io interface for basically anything since zif 0.16.0
io: std.Io,
/// Stack of saved stack tops for `pushTop`/`popTop` nesting.
top_stack: std.ArrayList(SavedTop) = .empty,

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

    if (builtin.mode == .Debug and self.top_stack.items.len > 0) {
        std.debug.print("zua: {d} unmatched pushTop call(s)\n", .{self.top_stack.items.len});
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.Io.File.Writer.init(.stderr(), self.io, stderr_buf[0..]);
        const terminal: std.Io.Terminal = .{
            .writer = &stderr_writer.interface,
            .mode = .no_color,
        };
        for (self.top_stack.items) |*entry| {
            const trace: std.debug.StackTrace = .{
                .return_addresses = entry.trace.frames[0..entry.trace.count],
                .skipped = .none,
            };
            std.debug.writeStackTrace(&trace, terminal) catch {};
        }
        stderr_writer.interface.flush() catch {};
        @panic("zua: unbalanced pushTop/popTop detected");
    }

    self.top_stack.deinit(self.allocator);
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

/// Creates or reuses a ZuaState inside an existing `lua_State*`. Uses a
/// suffix-based registry key so dylib reloads can recover the same state.
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

/// Closes the Lua state. Zua-owned runtime state is cleaned up when Lua
/// collects the state userdata.
pub fn deinit(self: *State) void {
    lua.deinit(self.luaState);
}

/// Pushes the metatable for T onto the stack. On first call the metatable
/// is built from `T`'s `ZUA_SHAPE` metadata: declared methods and metamethods
/// are wired through trampolines and cached by `@typeName(T)`.
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

/// Borrowed handle to the Lua globals table (`_G`). Each call pushes a
/// value onto the Lua stack that must be released or balanced. Use
/// `addGlobals` to write into it without managing the stack yourself.
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
    try Mapper.Encoder.Internals.fillTable(ctx, _globals, value);
}

/// Borrowed handle to the Lua registry. Each call pushes a value onto the
/// Lua stack that must be released or balanced. Use this to store host state
/// via `setLightUserdata("key", &state)`.
pub fn registry(self: *State) Table {
    lua.pushValue(self.luaState, lua.REGISTRY_INDEX);
    return Table.fromStack(self, -1);
}

/// Saves the current stack top for later restoration with `popTop`.
///
/// Use with `defer state.popTop()` around code that may push/pop values,
/// mirroring the Lua C API pattern of saving and restoring the stack.
/// In debug builds, the call site is captured to detect unbalanced usage.
pub fn pushTop(self: *State) void {
    var entry: SavedTop = .{
        .top = lua.getTop(self.luaState),
        .trace = if (builtin.mode == .Debug) .{ .frames = [_]usize{0} ** 8, .count = 0 } else {},
    };
    if (builtin.mode == .Debug) {
        const result = std.debug.captureCurrentStackTrace(.{ .first_address = @returnAddress() }, &entry.trace.frames);
        entry.trace.count = result.return_addresses.len;
    }
    self.top_stack.append(self.allocator, entry) catch @panic("OOM");
}

/// Restores the stack top to the value saved by the matching `pushTop`.
pub fn popTop(self: *State) void {
    lua.setTop(self.luaState, self.top_stack.pop().?.top);
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
