const std = @import("std");
const Args = @import("args.zig").Args;
const lua = @import("lua.zig");
const Zua = @import("zua.zig").Zua;

/// Errors returned by typed table reads.
pub const Error = error{
    InvalidKeyType,
    InvalidValueType,
    InvalidType,
    MissingField,
    OutOfRange,
};

/// Handle to a Lua table currently live on the stack.
pub const Table = struct {
    state: *lua.State,
    allocator: std.mem.Allocator,
    index: lua.StackIndex,
    owns_stack_slot: bool,

    /// Creates an owning table handle for a stack slot pushed by the wrapper.
    pub fn fromStack(state: *lua.State, allocator: std.mem.Allocator, index: lua.StackIndex) Table {
        return fromStackWithOwnership(state, allocator, index, true);
    }

    /// Creates a borrowed table handle for a stack slot owned by some other API operation.
    pub fn fromBorrowed(state: *lua.State, allocator: std.mem.Allocator, index: lua.StackIndex) Table {
        return fromStackWithOwnership(state, allocator, index, false);
    }

    fn fromStackWithOwnership(state: *lua.State, allocator: std.mem.Allocator, index: lua.StackIndex, owns_stack_slot: bool) Table {
        return .{
            .state = state,
            .allocator = allocator,
            .index = lua.absIndex(state, index),
            .owns_stack_slot = owns_stack_slot,
        };
    }

    /// Stores `value` under `key`.
    pub fn set(self: Table, key: anytype, value: anytype) void {
        const Key = @TypeOf(key);

        if (comptime isStringKeyType(Key)) {
            const key_text = coerceStringKey(key);
            pushValueToStack(self.state, self.allocator, value);
            lua.setField(self.state, self.index, key_text);
            return;
        }

        const key_value = coerceIntegerKey(key);
        pushValueToStack(self.state, self.allocator, value);
        lua.setIndex(self.state, self.index, key_value);
    }

    /// Populates this table from a Zig struct, array, tuple, or non-string slice.
    pub fn fill(self: Table, value: anytype) void {
        const T = @TypeOf(value);

        switch (@typeInfo(T)) {
            .@"struct" => |info| {
                if (info.is_tuple) {
                    inline for (value, 0..) |item, index| {
                        self.set(index + 1, item);
                    }
                    return;
                }

                inline for (info.fields) |field| {
                    self.set(field.name, @field(value, field.name));
                }
            },
            .array => {
                for (value, 0..) |item, index| {
                    self.set(index + 1, item);
                }
            },
            .pointer => |pointer| switch (pointer.size) {
                .slice => {
                    if (comptime isStringValueType(T)) {
                        @compileError("string-like values must be stored as Lua strings, not table fills");
                    }

                    for (value, 0..) |item, index| {
                        self.set(index + 1, item);
                    }
                },
                else => @compileError("unsupported table fill type: " ++ @typeName(T)),
            },
            else => @compileError("unsupported table fill type: " ++ @typeName(T)),
        }
    }

    /// Reads `table[key]` and converts it to `T`.
    pub fn get(self: Table, key: anytype, comptime T: type) Error!T {
        const Key = @TypeOf(key);

        if (comptime isStringKeyType(Key)) {
            _ = lua.getField(self.state, self.index, coerceStringKey(key));
        } else {
            _ = lua.getIndex(self.state, self.index, coerceIntegerKey(key));
        }

        if (T == Table) {
            if (lua.valueType(self.state, -1) != .table) {
                lua.pop(self.state, 1);
                return error.InvalidType;
            }

            return Table.fromStack(self.state, self.allocator, -1);
        }

        defer lua.pop(self.state, 1);
        if (lua.valueType(self.state, -1) == .none or lua.valueType(self.state, -1) == .nil) return error.MissingField;
        return decodeValue(T, self.state, -1);
    }

    pub fn getStruct(self: Table, comptime T: type) Error!T {
        var result: T = undefined;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            @field(result, field.name) = try self.get(field.name, field.type);
        }
        return result;
    }

    /// Registers a Zig callback as `table[key]`.
    pub fn setFn(self: Table, key: [:0]const u8, comptime f: anytype) void {
        lua.pushCFunction(self.state, wrap(f));
        lua.setField(self.state, self.index, key);
    }

    /// Stores a light userdata pointer under `key`.
    pub fn setLightUserdata(self: Table, key: [:0]const u8, ptr: anytype) void {
        lua.pushLightUserdata(self.state, ptr);
        lua.setField(self.state, self.index, key);
    }

    /// Loads a light userdata pointer from `key` and casts it to `*T`.
    pub fn getLightUserdata(self: Table, key: [:0]const u8, comptime T: type) Error!*T {
        _ = lua.getField(self.state, self.index, key);
        defer lua.pop(self.state, 1);

        const value_type = lua.valueType(self.state, -1);
        if (value_type == .none or value_type == .nil) return error.MissingField;

        const ptr = lua.toLightUserdata(self.state, -1) orelse return error.InvalidType;
        return @ptrCast(@alignCast(ptr));
    }

    /// Sets `mt` as the metatable for this table.
    pub fn setMetatable(self: Table, mt: Table) void {
        lua.pushValue(self.state, mt.index);
        _ = lua.setMetatable(self.state, self.index);
    }

    /// Removes this table from the stack when the handle owns that stack slot.
    pub fn pop(self: Table) void {
        if (!self.owns_stack_slot) return;
        lua.remove(self.state, self.index);
    }

    /// Pushes a Zig value onto the Lua stack using the same conversion rules as `set`.
    pub fn pushValueToStack(state: *lua.State, allocator: std.mem.Allocator, value: anytype) void {
        const T = @TypeOf(value);

        if (@typeInfo(T) == .optional) {
            if (value) |unwrapped| {
                pushValueToStack(state, allocator, unwrapped);
            } else {
                lua.pushNil(state);
            }
            return;
        }

        if (T == Table) {
            lua.pushValue(state, value.index);
            return;
        }

        if (T == bool) {
            lua.pushBoolean(state, value);
            return;
        }

        if (comptime isStringValueType(T)) {
            lua.pushString(state, value);
            return;
        }

        if (comptime isTableConvertibleType(T)) {
            lua.createTable(state, Table.inferArrayCapacity(value), Table.inferRecordCapacity(value));
            const nested = Table.fromStack(state, allocator, -1);
            nested.fill(value);
            return;
        }

        switch (@typeInfo(T)) {
            .int, .comptime_int => {
                lua.pushInteger(state, std.math.cast(lua.Integer, value) orelse @panic("integer value out of range for Lua"));
                return;
            },
            .float, .comptime_float => {
                lua.pushNumber(state, @as(lua.Number, value));
                return;
            },
            else => @compileError("unsupported table value type: " ++ @typeName(T)),
        }
    }

    /// Infers the array capacity for a Zig value that can be converted into a Lua table.
    pub fn inferArrayCapacity(value: anytype) i32 {
        const T = @TypeOf(value);

        return switch (@typeInfo(T)) {
            .@"struct" => |info| if (info.is_tuple) @intCast(info.fields.len) else 0,
            .array => @intCast(value.len),
            .pointer => |pointer| switch (pointer.size) {
                .slice => if (comptime isStringValueType(T)) @compileError("string-like values are not table-convertible") else std.math.cast(i32, value.len) orelse @panic("slice too large for Lua table"),
                else => @compileError("unsupported table conversion type: " ++ @typeName(T)),
            },
            else => @compileError("unsupported table conversion type: " ++ @typeName(T)),
        };
    }

    /// Infers the record capacity for a Zig value that can be converted into a Lua table.
    pub fn inferRecordCapacity(value: anytype) i32 {
        const T = @TypeOf(value);

        return switch (@typeInfo(T)) {
            .@"struct" => |info| if (info.is_tuple) 0 else @intCast(info.fields.len),
            .array, .pointer => 0,
            else => @compileError("unsupported table conversion type: " ++ @typeName(T)),
        };
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

fn isStringValueType(comptime T: type) bool {
    if (T == []const u8 or T == [:0]const u8) return true;

    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => @typeInfo(pointer.child) == .array,
            .slice => pointer.child == u8 and pointer.is_const,
            else => false,
        },
        else => false,
    };
}

// Table construction helpers

fn isTableConvertibleType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        .array => true,
        .pointer => |pointer| pointer.size == .slice and !isStringValueType(T),
        else => false,
    };
}

fn decodeValue(comptime T: type, state: *lua.State, index: lua.StackIndex) Error!T {
    if (T == bool) {
        if (lua.valueType(state, index) != .boolean) return error.InvalidType;
        return lua.toBoolean(state, index);
    }

    if (T == []const u8) {
        if (lua.valueType(state, index) != .string) return error.InvalidType;
        return lua.toString(state, index) orelse error.InvalidType;
    }

    if (T == [:0]const u8) {
        if (lua.valueType(state, index) != .string) return error.InvalidType;
        return lua.toString(state, index) orelse error.InvalidType;
    }

    switch (@typeInfo(T)) {
        .int => {
            if (!lua.isInteger(state, index)) return error.InvalidType;
            const value = lua.toInteger(state, index) orelse return error.InvalidType;
            return std.math.cast(T, value) orelse error.OutOfRange;
        },
        .float => {
            if (!lua.isNumber(state, index)) return error.InvalidType;
            const value = lua.toNumber(state, index) orelse return error.InvalidType;
            return std.math.cast(T, value) orelse error.OutOfRange;
        },
        else => @compileError("unsupported table get type: " ++ @typeName(T)),
    }
}

fn unwrapCallbackResultType(comptime ReturnType: type) type {
    return switch (@typeInfo(ReturnType)) {
        .error_union => |info| info.payload,
        else => ReturnType,
    };
}

fn isErrorUnionType(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

/// Builds the private C trampoline used by `Table.setFn`.
///
/// The trampoline recovers the owning `Zua`, initializes `Args`, converts
/// `!Result(...)` callbacks into `Result.errZig(err)`, and delays `lua_error`
/// until after Zig defers have run.
fn wrap(comptime f: anytype) lua.CFunction {
    const function_info = @typeInfo(@TypeOf(f)).@"fn";
    const ReturnType = function_info.return_type orelse @compileError("callback must have a return type");
    const CallbackResultType = unwrapCallbackResultType(ReturnType);

    if (!@hasDecl(CallbackResultType, "value_types") or !@hasDecl(CallbackResultType, "value_count")) {
        @compileError("callback must return zua.Result(T), zua.Result(.{ ... }), or an error union containing one of them");
    }

    return struct {
        fn trampoline(state_: ?*lua.State) callconv(.c) c_int {
            const state = state_ orelse unreachable;
            const zua = Zua.fromState(state);
            const baseline = lua.getTop(state);

            const args = Args.init(state, zua.allocator, baseline);
            const raw_result = f(zua, args);
            const result: CallbackResultType = if (comptime isErrorUnionType(ReturnType))
                raw_result catch |err| CallbackResultType.errZig(err)
            else
                raw_result;

            if (result.failure) |failure| {
                switch (failure) {
                    .static_message => |message| lua.pushString(state, message),
                    .owned_message => |message| {
                        lua.pushString(state, message);
                        zua.allocator.free(message);
                    },
                    .zig_error => |err| lua.pushString(state, @errorName(err)),
                }
                return lua.raiseError(state);
            }

            var success = result;
            defer success.deinit(zua.allocator);
            success.pushValues(state, zua.allocator);

            return @intCast(CallbackResultType.value_count);
        }
    }.trampoline;
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
