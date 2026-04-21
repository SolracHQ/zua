//! Table handles provide a safe wrapper around Lua table objects.
//! They support borrowed, stack-owned, and registry-owned lifetimes and centralize conversions between Zig values and Lua tables.
const std = @import("std");
const lua = @import("../../lua/lua.zig");
const Handle = @import("../handlers/handlers.zig").Handle;
const Mapper = @import("../mapper/mapper.zig");
const Context = @import("../state/context.zig").Context;
const State = @import("../state/state.zig");
const Function = @import("function.zig");
const Userdata = @import("userdata.zig").Userdata;

/// Errors returned by typed table reads.
pub const Error = error.Failed;

/// Handle to a Lua table with three ownership modes: borrowed, stack_owned, or registry_owned.
pub const Table = @This();

/// Global Zua state pointer used to access the Lua VM and allocators.
/// This pointer is borrowed by the handle and is not owned by `Table`.
state: *State,
/// Ownership mode for the referenced Lua table value.
/// The handle may represent a borrowed stack slot, a stack-owned slot, or a registry reference.
handle: Handle,

/// Creates a stack-owned table handle that must be released via `release()`.
///
/// Arguments:
/// - z: The global Zua state containing the Lua VM.
/// - index: The stack index of the created table.
///
/// Returns:
/// - Table: A handle owning the table stack slot.
///
/// Example:
/// ```zig
/// var tbl = Table.fromStack(z, -1);
/// defer tbl.release();
/// ```
pub fn fromStack(state: *State, index: lua.StackIndex) Table {
    return .{
        .state = state,
        .handle = .{ .stack_owned = lua.absIndex(state.luaState, index) },
    };
}

/// Creates a borrowed table handle for a stack slot owned by another API operation.
/// The borrowed handle does not own the stack slot and must not be released.
///
/// Arguments:
/// - state: The global Zua state containing the Lua VM.
/// - index: The stack index of the borrowed table.
///
/// Returns:
/// - Table: A borrowed handle for the existing stack slot.
///
/// Example:
/// ```zig
/// const tbl = Table.fromBorrowed(state, 1);
/// ```
pub fn fromBorrowed(state: *State, index: lua.StackIndex) Table {
    return .{
        .state = state,
        .handle = .{ .borrowed = lua.absIndex(state.luaState, index) },
    };
}

/// Creates a new Lua table with optional capacity hints and returns a stack-owned handle.
/// Pass `0` for capacity hints if the final size is unknown; Lua will resize internally.
///
/// Arguments:
/// - state: The global Zua state containing the Lua VM.
/// - array_capacity: The expected number of array elements.
/// - record_capacity: The expected number of name/value pairs.
///
/// Returns:
/// - Table: A stack-owned handle for the new table.
///
/// Example:
/// ```zig
/// const tbl = Table.create(state, 4, 2);
/// defer tbl.release();
/// ```
pub fn create(state: *State, array_capacity: i32, record_capacity: i32) Table {
    lua.createTable(state.luaState, array_capacity, record_capacity);
    return Table.fromStack(state, -1);
}

/// Converts a Zig struct, array, tuple, or slice into a Lua table recursively.
/// Array elements become integer keys and struct fields become string keys.
/// Nested structs and arrays are converted recursively.
///
/// Arguments:
/// - state: The global Zua state containing the Lua VM.
/// - value: The Zig value to convert into a Lua table.
///
/// Returns:
/// - Table: A stack-owned handle for the converted Lua table.
///
/// Example:
/// ```zig
/// const tbl = Table.from(state, .{ .x = 1, .y = 2 });
/// defer tbl.release();
/// ```
pub fn from(state: *State, value: anytype) Table {
    const table = Table.create(state, Mapper.Encoder.inferArrayCapacity(value), Mapper.Encoder.inferRecordCapacity(value));
    Mapper.Encoder.fillTable(table, value);
    return table;
}

/// Anchors this table in the Lua registry for persistent storage.
/// The returned handle owns the registry reference and may be released with `release()`.
///
/// Returns:
/// - Table: A registry-owned handle that outlives the current Lua stack.
///
/// Example:
/// ```zig
/// const owned = tbl.owned();
/// defer owned.release();
/// ```
pub fn owned(self: Table) Table {
    return .{
        .state = self.state,
        .handle = self.handle.owned(self.state),
    };
}

/// Anchors this table in the Lua registry and releases the old stack-owned
/// handle if applicable.
///
/// Promote a stack-owned table into registry ownership without leaving the
/// original stack slot behind.
pub fn takeOwnership(self: Table) Table {
    return .{
        .state = self.state,
        .handle = self.handle.takeOwnership(self.state),
    };
}

/// Stores `value` under `key` in the Lua table.
///
/// Arguments:
/// - ctx: The current call context used for temporary allocations and error reporting.
/// - key: The table key, which may be a string or integer type.
/// - value: The value to store in the table.
///
/// Example:
/// ```zig
/// tbl.set(ctx, "name", "Alice");
/// tbl.set(ctx, 1, 42);
/// ```
pub fn set(self: Table, ctx: *Context, key: anytype, value: anytype) !void {
    const Key = @TypeOf(key);
    const index = switch (self.handle) {
        inline else => |idx| idx,
    };

    if (comptime isStringKeyType(Key)) {
        const key_text = coerceStringKey(key);
        try Mapper.Encoder.pushValue(ctx, value);
        lua.setField(self.state.luaState, index, key_text);
        return;
    }

    const key_value = coerceIntegerKey(key);
    try Mapper.Encoder.pushValue(ctx, value);
    lua.setIndex(self.state.luaState, index, key_value);
}

/// Reads `table[key]` and converts it to `T`.
/// If `T == Table`, returns a stack-owned table handle for the result.
///
/// Arguments:
/// - ctx: The current call context used for decoding and error reporting.
/// - key: The table key to lookup, which may be a string or integer type.
/// - T: The expected return type.
///
/// Returns:
/// - !T: The decoded value on success or `error.Failed` on conversion failure.
///
/// Example:
/// ```zig
/// const value = try tbl.get(ctx, "name", []const u8);
/// const nested = try tbl.get(ctx, "child", Table);
/// ```
pub fn get(self: Table, ctx: *Context, key: anytype, comptime T: type) !T {
    const Key = @TypeOf(key);
    const index = switch (self.handle) {
        inline else => |idx| idx,
    };

    if (comptime isStringKeyType(Key)) {
        _ = lua.getField(self.state.luaState, index, coerceStringKey(key));
    } else {
        _ = lua.getIndex(self.state.luaState, index, coerceIntegerKey(key));
    }

    return try Mapper.Decoder.decodeAt(ctx, -1, T);
}

/// Checks if `key` exists in the table.
///
/// Arguments:
/// - key: The table key to lookup, which may be a string or integer type.
///
/// Returns:
/// - bool: `true` if the key exists and is not `nil`, `false` otherwise.
///
/// Example:
/// ```zig
/// if (tbl.has("name")) {
///     // key exists
/// }
/// ```
pub fn has(self: Table, key: anytype) bool {
    const Key = @TypeOf(key);
    const index = switch (self.handle) {
        inline else => |idx| idx,
    };

    if (comptime isStringKeyType(Key)) {
        _ = lua.getField(self.state.luaState, index, coerceStringKey(key));
    } else {
        _ = lua.getIndex(self.state.luaState, index, coerceIntegerKey(key));
    }

    defer lua.pop(self.state.luaState, 1);
    return lua.valueType(self.state.luaState, -1) != .none and lua.valueType(self.state.luaState, -1) != .nil;
}

/// Stores a light userdata pointer under `key`.
///
/// Arguments:
/// - key: The string key under which to store the pointer.
/// - ptr: The light userdata pointer.
///
/// Example:
/// ```zig
/// tbl.setLightUserdata("ctx", some_ptr);
/// ```
pub fn setLightUserdata(self: Table, key: [:0]const u8, ptr: anytype) void {
    const index = switch (self.handle) {
        inline else => |idx| idx,
    };
    lua.pushLightUserdata(self.state.luaState, ptr);
    lua.setField(self.state.luaState, index, key);
}

/// Loads a light userdata pointer from `key` and casts it to `*T`.
///
/// Returns:
/// - Error!*T: The pointer cast on success or `error.InvalidType` when the
///   Lua value is not a valid light userdata.
///
/// Example:
/// ```zig
/// const ptr = try tbl.getLightUserdata(ctx, "ctx", *MyType);
/// ```
pub fn getLightUserdata(self: Table, key: [:0]const u8, comptime T: type) Error!*T {
    const index = switch (self.handle) {
        inline else => |idx| idx,
    };
    _ = lua.getField(self.state.luaState, index, key);
    defer lua.pop(self.state.luaState, 1);

    const value_type = lua.valueType(self.state.luaState, -1);
    if (value_type == .none or value_type == .nil) return error.InvalidType;

    const ptr = lua.toLightUserdata(self.state.luaState, -1) orelse return error.InvalidType;
    return @ptrCast(@alignCast(ptr));
}

/// Sets `mt` as the metatable for this table.
///
/// Arguments:
/// - mt: The metatable table handle.
///
/// Example:
/// ```zig
/// tbl.setMetatable(meta_tbl);
/// ```
pub fn setMetatable(self: Table, mt: Table) void {
    const index = switch (self.handle) {
        inline else => |idx| idx,
    };
    const mt_index = switch (mt.handle) {
        inline else => |idx| idx,
    };
    lua.pushValue(self.state.luaState, mt_index);
    _ = lua.setMetatable(self.state.luaState, index);
}

/// Releases this table from the stack (if stack-owned) or registry (if registry-owned).
///
/// Example:
/// ```zig
/// tbl.release();
/// ```
pub fn release(self: Table) void {
    self.handle.release(self.state);
}

// Key helpers

fn isStringKeyType(comptime T: type) bool {
    if (T == [:0]const u8) return true;

    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => @typeInfo(pointer.child) == .array,
            .slice => pointer.sentinel() != null and pointer.child == u8 and pointer.is_const,
            else => false,
        },
        else => false,
    };
}

fn coerceStringKey(key: anytype) [:0]const u8 {
    const T = @TypeOf(key);

    if (T == [:0]const u8) return key;

    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => key,
            .slice => key,
            else => @compileError("Unsupported string key type: " ++ @typeName(T)),
        },
        else => @compileError("Unsupported string key type: " ++ @typeName(T)),
    };
}

fn coerceIntegerKey(key: anytype) lua.Integer {
    const T = @TypeOf(key);

    return switch (@typeInfo(T)) {
        .comptime_int, .int => std.math.cast(lua.Integer, key) orelse @panic("table integer key out of range"),
        else => @compileError("Unsupported table key type: " ++ @typeName(T)),
    };
}
