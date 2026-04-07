const std = @import("std");
const lua = @import("../lua/lua.zig");
const translation = @import("translation.zig");
const Zua = @import("zua.zig").Zua;
const Result = @import("result.zig").Result;

/// Errors returned by typed table reads.
pub const Error = translation.ParseError;

/// Handle to a Lua table with three ownership modes: borrowed, stack_owned, or registry_owned.
pub const Table = struct {
    z: *Zua,
    handle: union(translation.HandleOwnership) {
        borrowed: lua.StackIndex,
        stack_owned: lua.StackIndex,
        registry_owned: c_int,
    },

    /// Creates a stack-owned table handle that must be released via .release().
    pub fn fromStack(z: *Zua, index: lua.StackIndex) Table {
        return .{
            .z = z,
            .handle = .{ .stack_owned = lua.absIndex(z.state, index) },
        };
    }

    /// Creates a borrowed table handle for a stack slot owned by some other API operation.
    pub fn fromBorrowed(z: *Zua, index: lua.StackIndex) Table {
        return .{
            .z = z,
            .handle = .{ .borrowed = lua.absIndex(z.state, index) },
        };
    }

    /// Anchors this table in the Lua registry for persistent storage.
    pub fn takeOwnership(self: Table) Table {
        const index = switch (self.handle) {
            inline else => |idx| idx,
        };

        lua.pushValue(self.z.state, index);
        const ref = lua.ref(self.z.state, lua.REGISTRY_INDEX);

        return .{
            .z = self.z,
            .handle = .{ .registry_owned = ref },
        };
    }

    /// Stores `value` under `key`.
    pub fn set(self: Table, key: anytype, value: anytype) void {
        const Key = @TypeOf(key);
        const index = switch (self.handle) {
            inline else => |idx| idx,
        };

        if (comptime isStringKeyType(Key)) {
            const key_text = coerceStringKey(key);
            translation.pushValue(self.z, value);
            lua.setField(self.z.state, index, key_text);
            return;
        }

        const key_value = coerceIntegerKey(key);
        translation.pushValue(self.z, value);
        lua.setIndex(self.z.state, index, key_value);
    }

    /// Reads `table[key]` and converts it to `T`, returning a Result or error.
    pub fn get(self: Table, key: anytype, comptime T: type) translation.ParseError!Result(T) {
        const Key = @TypeOf(key);
        const index = switch (self.handle) {
            inline else => |idx| idx,
        };

        if (comptime isStringKeyType(Key)) {
            _ = lua.getField(self.z.state, index, coerceStringKey(key));
        } else {
            _ = lua.getIndex(self.z.state, index, coerceIntegerKey(key));
        }

        if (T == Table) {
            if (lua.valueType(self.z.state, -1) != .table) {
                lua.pop(self.z.state, 1);
                return Result(T).errStatic("expected table");
            }

            const tbl = Table.fromStack(self.z, -1);
            return Result(T).ok(tbl);
        }

        defer lua.pop(self.z.state, 1);
        if (lua.valueType(self.z.state, -1) == .none or lua.valueType(self.z.state, -1) == .nil) {
            if (comptime @typeInfo(T) == .optional) {
                return Result(T).ok(null);
            } else {
                return Result(T).errStatic("key not found");
            }
        }
        return try translation.decodeValue(self.z, -1, T, .borrowed);
    }

    /// Checks if `key` exists in the table.
    pub fn has(self: Table, key: anytype) bool {
        const Key = @TypeOf(key);
        const index = switch (self.handle) {
            inline else => |idx| idx,
        };

        if (comptime isStringKeyType(Key)) {
            _ = lua.getField(self.z.state, index, coerceStringKey(key));
        } else {
            _ = lua.getIndex(self.z.state, index, coerceIntegerKey(key));
        }

        defer lua.pop(self.z.state, 1);
        return lua.valueType(self.z.state, -1) != .none and lua.valueType(self.z.state, -1) != .nil;
    }

    /// Registers a Zig callback as `table[key]`.
    pub fn setFn(self: Table, key: [:0]const u8, zuaFn: anytype) void {
        const ZuaFn = @TypeOf(zuaFn);
        const index = switch (self.handle) {
            inline else => |idx| idx,
        };

        if (!@hasDecl(ZuaFn, "trampoline")) {
            @compileError("setFn expects a value returned by zua.ZuaFn.from(...) or zua.ZuaFn.pure(...)");
        }

        lua.pushCFunction(self.z.state, ZuaFn.trampoline());
        lua.setField(self.z.state, index, key);
    }

    /// Stores a light userdata pointer under `key`.
    pub fn setLightUserdata(self: Table, key: [:0]const u8, ptr: anytype) void {
        const index = switch (self.handle) {
            inline else => |idx| idx,
        };
        lua.pushLightUserdata(self.z.state, ptr);
        lua.setField(self.z.state, index, key);
    }

    /// Loads a light userdata pointer from `key` and casts it to `*T`.
    pub fn getLightUserdata(self: Table, key: [:0]const u8, comptime T: type) Error!*T {
        const index = switch (self.handle) {
            inline else => |idx| idx,
        };
        _ = lua.getField(self.z.state, index, key);
        defer lua.pop(self.z.state, 1);

        const value_type = lua.valueType(self.z.state, -1);
        if (value_type == .none or value_type == .nil) return error.InvalidType;

        const ptr = lua.toLightUserdata(self.z.state, -1) orelse return error.InvalidType;
        return @ptrCast(@alignCast(ptr));
    }

    /// Sets `mt` as the metatable for this table.
    pub fn setMetatable(self: Table, mt: Table) void {
        const index = switch (self.handle) {
            inline else => |idx| idx,
        };
        const mt_index = switch (mt.handle) {
            inline else => |idx| idx,
        };
        lua.pushValue(self.z.state, mt_index);
        _ = lua.setMetatable(self.z.state, index);
    }

    /// Releases this table from the stack (if stack-owned) or registry (if registry-owned).
    pub fn release(self: Table) void {
        switch (self.handle) {
            .borrowed => {},
            .stack_owned => |index| lua.remove(self.z.state, index),
            .registry_owned => |ref| lua.unref(self.z.state, lua.REGISTRY_INDEX, ref),
        }
    }

    /// Removes this table from the stack when the handle owns that stack slot.
    /// Deprecated: use .release() instead.
    pub fn pop(self: Table) void {
        self.release();
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

    const zua = try zua_mod.Zua.init(std.testing.allocator, std.testing.io);
    defer zua.deinit();

    const table = zua.createTable(0, 4);
    defer table.pop();

    table.set("answer", 42);
    table.set("ok", true);
    table.set("name", "zua");

    try std.testing.expectEqual(@as(i32, 42), (try table.get("answer", i32)).unwrap());
    try std.testing.expectEqual(true, (try table.get("ok", bool)).unwrap());
    try std.testing.expectEqualStrings("zua", (try table.get("name", []const u8)).unwrap());
}

test "table round-trips light userdata" {
    const zua_mod = @import("zua.zig");

    const zua = try zua_mod.Zua.init(std.testing.allocator, std.testing.io);
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

    const zua = try zua_mod.Zua.init(std.testing.allocator, std.testing.io);
    defer zua.deinit();

    const tag_values = [_][]const u8{ "zig", "lua", "bindings" };
    const guide = zua.tableFrom(.{
        .name = "guided-tour",
        .answer = 42,
        .tags = tag_values,
    });
    defer guide.pop();

    try std.testing.expectEqualStrings("guided-tour", (try guide.get("name", []const u8)).unwrap());
    try std.testing.expectEqual(@as(i32, 42), (try guide.get("answer", i32)).unwrap());

    const tags = (try guide.get("tags", Table)).unwrap();
    defer tags.pop();
    try std.testing.expectEqualStrings("zig", (try tags.get(1, []const u8)).unwrap());
    try std.testing.expectEqualStrings("lua", (try tags.get(2, []const u8)).unwrap());
    try std.testing.expectEqualStrings("bindings", (try tags.get(3, []const u8)).unwrap());
}
