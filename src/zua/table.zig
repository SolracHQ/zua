const std = @import("std");
const lua = @import("../lua/lua.zig");
const translation = @import("translation.zig");
const Zua = @import("zua.zig").Zua;

/// Errors returned by typed table reads.
pub const Error = translation.ParseError;

/// Handle to a Lua table currently live on the stack.
pub const Table = struct {
    z: *Zua,
    index: lua.StackIndex,
    owns_stack_slot: bool,

    /// Creates an owning table handle for a stack slot pushed by the wrapper.
    pub fn fromStack(z: *Zua, index: lua.StackIndex) Table {
        return fromStackWithOwnership(z, index, true);
    }

    /// Creates a borrowed table handle for a stack slot owned by some other API operation.
    pub fn fromBorrowed(z: *Zua, index: lua.StackIndex) Table {
        return fromStackWithOwnership(z, index, false);
    }

    fn fromStackWithOwnership(z: *Zua, index: lua.StackIndex, owns_stack_slot: bool) Table {
        return .{
            .z = z,
            .index = lua.absIndex(z.state, index),
            .owns_stack_slot = owns_stack_slot,
        };
    }

    /// Stores `value` under `key`.
    pub fn set(self: Table, key: anytype, value: anytype) void {
        const Key = @TypeOf(key);

        if (comptime isStringKeyType(Key)) {
            const key_text = coerceStringKey(key);
            translation.pushValue(self.z, value);
            lua.setField(self.z.state, self.index, key_text);
            return;
        }

        const key_value = coerceIntegerKey(key);
        translation.pushValue(self.z, value);
        lua.setIndex(self.z.state, self.index, key_value);
    }

    /// Reads `table[key]` and converts it to `T`.
    pub fn get(self: Table, key: anytype, comptime T: type) Error!T {
        const Key = @TypeOf(key);

        if (comptime isStringKeyType(Key)) {
            _ = lua.getField(self.z.state, self.index, coerceStringKey(key));
        } else {
            _ = lua.getIndex(self.z.state, self.index, coerceIntegerKey(key));
        }

        if (T == Table) {
            if (lua.valueType(self.z.state, -1) != .table) {
                lua.pop(self.z.state, 1);
                return error.InvalidType;
            }

            return Table.fromStack(self.z, -1);
        }

        defer lua.pop(self.z.state, 1);
        if (lua.valueType(self.z.state, -1) == .none or lua.valueType(self.z.state, -1) == .nil) {
            if (comptime @typeInfo(T) == .optional) {
                return null;
            } else {
                return error.InvalidType;
            }
        }
        return translation.decodeValue(self.z, -1, T, .borrowed);
    }

    /// Registers a Zig callback as `table[key]`.
    pub fn setFn(self: Table, key: [:0]const u8, zuaFn: anytype) void {
        const ZuaFn = @TypeOf(zuaFn);

        if (!@hasDecl(ZuaFn, "trampoline")) {
            @compileError("setFn expects a value returned by zua.ZuaFn.from(...) or zua.ZuaFn.pure(...)");
        }

        lua.pushCFunction(self.z.state, ZuaFn.trampoline());
        lua.setField(self.z.state, self.index, key);
    }

    /// Stores a light userdata pointer under `key`.
    pub fn setLightUserdata(self: Table, key: [:0]const u8, ptr: anytype) void {
        lua.pushLightUserdata(self.z.state, ptr);
        lua.setField(self.z.state, self.index, key);
    }

    /// Loads a light userdata pointer from `key` and casts it to `*T`.
    pub fn getLightUserdata(self: Table, key: [:0]const u8, comptime T: type) Error!*T {
        _ = lua.getField(self.z.state, self.index, key);
        defer lua.pop(self.z.state, 1);

        const value_type = lua.valueType(self.z.state, -1);
        if (value_type == .none or value_type == .nil) return error.InvalidType;

        const ptr = lua.toLightUserdata(self.z.state, -1) orelse return error.InvalidType;
        return @ptrCast(@alignCast(ptr));
    }

    /// Sets `mt` as the metatable for this table.
    pub fn setMetatable(self: Table, mt: Table) void {
        lua.pushValue(self.z.state, mt.index);
        _ = lua.setMetatable(self.z.state, self.index);
    }

    /// Removes this table from the stack when the handle owns that stack slot.
    pub fn pop(self: Table) void {
        if (!self.owns_stack_slot) return;
        lua.remove(self.z.state, self.index);
    }
};

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
            else => @compileError("unsupported string key type: " ++ @typeName(T)),
        },
        else => @compileError("unsupported string key type: " ++ @typeName(T)),
    };
}

fn coerceIntegerKey(key: anytype) lua.Integer {
    const T = @TypeOf(key);

    return switch (@typeInfo(T)) {
        .comptime_int, .int => std.math.cast(lua.Integer, key) orelse @panic("table integer key out of range"),
        else => @compileError("unsupported table key type: " ++ @typeName(T)),
    };
}

test "table set and get values" {
    const zua_mod = @import("zua.zig");

    const zua = try zua_mod.Zua.init(std.testing.allocator);
    defer zua.deinit();

    const table = zua.createTable(0, 4);
    defer table.pop();

    table.set("answer", 42);
    table.set("ok", true);
    table.set("name", "zua");

    try std.testing.expectEqual(@as(i32, 42), try table.get("answer", i32));
    try std.testing.expectEqual(true, try table.get("ok", bool));
    try std.testing.expectEqualStrings("zua", try table.get("name", []const u8));
}

test "table round-trips light userdata" {
    const zua_mod = @import("zua.zig");

    const zua = try zua_mod.Zua.init(std.testing.allocator);
    defer zua.deinit();

    var value: i32 = 7;
    const table = zua.createTable(0, 1);
    defer table.pop();

    table.setLightUserdata("value", &value);
    const ptr = try table.getLightUserdata("value", i32);

    try std.testing.expectEqual(@as(i32, 7), ptr.*);
}

test "table fill converts structs and nested arrays" {
    const zua_mod = @import("zua.zig");

    const zua = try zua_mod.Zua.init(std.testing.allocator);
    defer zua.deinit();

    const tag_values = [_][]const u8{ "zig", "lua", "bindings" };
    const guide = zua.tableFrom(.{
        .name = "guided-tour",
        .answer = 42,
        .tags = tag_values,
    });
    defer guide.pop();

    try std.testing.expectEqualStrings("guided-tour", try guide.get("name", []const u8));
    try std.testing.expectEqual(@as(i32, 42), try guide.get("answer", i32));

    const tags = try guide.get("tags", Table);
    defer tags.pop();
    try std.testing.expectEqualStrings("zig", try tags.get(1, []const u8));
    try std.testing.expectEqualStrings("lua", try tags.get(2, []const u8));
    try std.testing.expectEqualStrings("bindings", try tags.get(3, []const u8));
}
