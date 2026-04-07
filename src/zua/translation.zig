const std = @import("std");
const lua = @import("../lua/lua.zig");
const meta = @import("meta.zig");

const Zua = @import("zua.zig").Zua;
const Table = @import("table.zig").Table;
const Result = @import("result.zig").Result;
const Strategy = meta.Strategy;

/// Errors returned by typed value decoding and parsing.
pub const ParseError = error{
    InvalidArity,
    InvalidType,
    OutOfMemory,
};

/// Ownership mode used when decoding tables/functions into handles.
pub const HandleOwnership = enum {
    borrowed, // temporary, no cleanup needed
    stack_owned, // must call .pop() to remove from stack
    registry_owned, // must call .release() to remove from registry
};

/// Decoded Lua primitive value, used by custom decode hooks.
///
/// Represents a Lua value after type-checking but before type-specific decoding.
/// The `table` variant holds a borrowed handle that is valid for
/// the duration of the decode hook execution (the value remains on the stack).
/// Function types are handled separately via decodeValue; they are not included here.
pub const Primitive = union(enum) {
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    table: Table,
    light_userdata: *anyopaque,
    userdata: *anyopaque,
    // nil, none, thread, and function are not represented
    // (nil/none handled upstream, thread unsupported, function handled separately)
};

/// Tuple type used to hold decoded callback arguments.
pub fn ParseResult(comptime types: anytype) type {
    comptime var field_types: [types.len]type = undefined;

    inline for (types, 0..) |T, index| {
        field_types[index] = T;
    }

    return std.meta.Tuple(&field_types);
}

/// Parses a sequence of Lua stack values into a typed Zig tuple.
///
/// Supports optional trailing arguments and returns `error.InvalidArity` when
/// the provided values do not match the requested tuple shape.
pub fn parseTuple(
    z: *Zua,
    start_index: lua.StackIndex,
    value_count: lua.StackCount,
    comptime types: anytype,
    table_ownership: HandleOwnership,
) ParseError!Result(ParseResult(types)) {
    var min_arity: usize = 0;

    inline for (types) |T| {
        if (!isOptional(T)) min_arity += 1;
    }

    if (value_count < min_arity or value_count > types.len) {
        return error.InvalidArity;
    }

    var values: ParseResult(types) = undefined;

    inline for (types, 0..) |T, index| {
        if (comptime isOptional(T)) {
            if (index >= value_count) {
                values[index] = null;
            } else {
                const stack_index = start_index + @as(lua.StackIndex, @intCast(index));

                if (lua.valueType(z.state, stack_index) == .nil) {
                    values[index] = null;
                } else {
                    const decoded = try decodeValue(
                        z,
                        stack_index,
                        optionalChild(T),
                        table_ownership,
                    );
                    if (decoded.failure) |failure| {
                        return Result(ParseResult(types)){ .failure = failure };
                    }
                    values[index] = decoded.value;
                }
            }
        } else {
            if (index >= value_count) return Result(ParseResult(types)).errStatic("invalid arity");

            const stack_index = start_index + @as(lua.StackIndex, @intCast(index));
            const decoded = try decodeValue(
                z,
                stack_index,
                T,
                table_ownership,
            );
            if (decoded.failure) |failure| {
                return Result(ParseResult(types)){ .failure = failure };
            }
            values[index] = decoded.value;
        }
    }

    return Result(ParseResult(types)).ok(values);
}

/// Builds a Primitive value from a Lua stack value at the given index.
///
/// Reads the Lua type, constructs the appropriate Primitive variant.
/// For tables, creates a borrowed Table handle.
/// Returns error.InvalidType for unsupported types (nil, none, thread, etc.).
fn buildPrimitive(z: *Zua, index: lua.StackIndex) ParseError!Primitive {
    const kind = lua.valueType(z.state, index);

    return switch (kind) {
        .boolean => Primitive{ .boolean = lua.toBoolean(z.state, index) },
        .number => blk: {
            if (lua.isInteger(z.state, index)) {
                const value = lua.toInteger(z.state, index) orelse return error.InvalidType;
                break :blk Primitive{ .integer = value };
            } else {
                const value = lua.toNumber(z.state, index) orelse return error.InvalidType;
                break :blk Primitive{ .float = value };
            }
        },
        .string => Primitive{ .string = lua.toString(z.state, index) orelse return error.InvalidType },
        .table => Primitive{ .table = Table.fromBorrowed(z, index) },
        .userdata => Primitive{ .userdata = lua.toUserdata(z.state, index) orelse return error.InvalidType },
        .light_userdata => Primitive{ .light_userdata = lua.toLightUserdata(z.state, index) orelse return error.InvalidType },
        else => error.InvalidType, // nil, none, thread, function, etc.
    };
}

/// Decodes a Lua value from the stack at `index` into type `T`.
/// Supports strings, numbers, booleans, tables, userdata, pointers, and optional values.
pub fn decodeValue(
    z: *Zua,
    index: lua.StackIndex,
    comptime T: type,
    table_ownership: HandleOwnership,
) ParseError!Result(T) {
    if (comptime isOptional(T)) {
        if (lua.valueType(z.state, index) == .nil) return Result(T).ok(null);
        const ChildType = optionalChild(T);
        const decoded = try decodeValue(z, index, ChildType, table_ownership);
        if (decoded.failure) |failure| {
            return Result(T).errStatic(failure.getErr());
        }
        return Result(T).ok(decoded.value);
    }

    // Check for custom decode hook first
    if (comptime meta.hasDecodeHook(T)) {
        const primitive = try buildPrimitive(z, index);
        return try T.ZUA_META.decode_hook(z, primitive);
    }

    switch (comptime @typeInfo(T)) {
        .pointer => |ptr_info| {
            if (ptr_info.size == .one) {
                const Pointee = ptr_info.child;

                if (@typeInfo(Pointee) == .@"struct" or @typeInfo(Pointee) == .@"union") {
                    const strategy = comptime meta.strategyOf(Pointee);

                    if (strategy == .object) {
                        if (lua.valueType(z.state, index) != .userdata) return error.InvalidType;
                        const raw = lua.toUserdata(z.state, index) orelse return error.InvalidType;
                        return Result(T).ok(@ptrCast(@alignCast(raw)));
                    }

                    if (strategy == .zig_ptr) {
                        if (lua.valueType(z.state, index) != .light_userdata) return Result(T).errStatic("expected light userdata");
                        const raw = lua.toLightUserdata(z.state, index) orelse return Result(T).errStatic("invalid light userdata");
                        return Result(T).ok(@ptrCast(@alignCast(raw)));
                    }

                    return Result(T).errStatic("expected object or pointer");
                }
            }

            // Handle non-string slices: decode from Lua array table
            if (comptime ptr_info.size == .slice and !isStringValueType(T)) {
                if (lua.valueType(z.state, index) != .table) return Result(T).errStatic("expected table");
                const table = Table.fromBorrowed(z, index);
                const slice = decodeSlice(T, z, table) catch {
                    return Result(T).errStatic("failed to decode slice");
                };
                return Result(T).ok(slice);
            }

            // Non-single or non-struct pointer: fall through to string/slice checks below.
        },
        .@"struct" => {
            const strategy = comptime meta.strategyOf(T);

            if (strategy == .object) {
                if (lua.valueType(z.state, index) != .userdata) return error.InvalidType;
                const raw = lua.toUserdata(z.state, index) orelse return error.InvalidType;
                const typed: *T = @ptrCast(@alignCast(raw));
                return Result(T).ok(typed.*);
            }

            if (strategy == .zig_ptr) {
                if (lua.valueType(z.state, index) != .light_userdata) return error.InvalidType;
                const raw = lua.toLightUserdata(z.state, index) orelse return error.InvalidType;
                const typed: *T = @ptrCast(@alignCast(raw));
                return Result(T).ok(typed.*);
            }

            if (T == Table) {
                if (lua.valueType(z.state, index) != .table) return Result(T).errStatic("expected table");
                const table_handle = switch (table_ownership) {
                    .borrowed => Table.fromBorrowed(z, index),
                    .stack_owned => Table.fromStack(z, index),
                    .registry_owned => Table.fromStack(z, index).takeOwnership(),
                };
                return Result(T).ok(table_handle);
            }

            // Check if T is a Function type
            if (comptime @hasDecl(T, "__isZuaFunction")) {
                if (lua.valueType(z.state, index) != .function) return Result(T).errStatic("expected function");
                const fn_handle = switch (table_ownership) {
                    .borrowed => T.fromBorrowed(z, index),
                    .stack_owned => T.fromStack(z, index),
                    .registry_owned => T.fromStack(z, index).takeOwnership(),
                };
                return Result(T).ok(fn_handle);
            }

            // .table strategy: decode by field name from a Lua table.
            if (lua.valueType(z.state, index) != .table) return error.InvalidType;
            const table = Table.fromBorrowed(z, index);
            return Result(T).ok(try decodeStruct(table, T));
        },
        .@"union" => {
            const strategy = comptime meta.strategyOf(T);

            if (strategy == .object) {
                if (lua.valueType(z.state, index) != .userdata) return error.InvalidType;
                const raw = lua.toUserdata(z.state, index) orelse return error.InvalidType;
                const typed: *T = @ptrCast(@alignCast(raw));
                return Result(T).ok(typed.*);
            }

            if (strategy == .zig_ptr) {
                if (lua.valueType(z.state, index) != .light_userdata) return error.InvalidType;
                const raw = lua.toLightUserdata(z.state, index) orelse return error.InvalidType;
                const typed: *T = @ptrCast(@alignCast(raw));
                return Result(T).ok(typed.*);
            }

            if (lua.valueType(z.state, index) != .table) return error.InvalidType;
            const table = Table.fromBorrowed(z, index);

            var found: ?T = null;

            inline for (@typeInfo(T).@"union".fields) |field| {
                const maybe_value = (table.get(field.name, ?field.type) catch return error.InvalidType).value;
                if (maybe_value) |v| {
                    if (found != null) return error.InvalidType;
                    found = @unionInit(T, field.name, v);
                }
            }

            return Result(T).ok(found orelse return error.InvalidType);
        },
        .@"enum" => {
            if (lua.valueType(z.state, index) != .integer) return error.InvalidType;
            const value = lua.toInteger(z.state, index) orelse return error.InvalidType;
            return std.meta.intToEnum(T, std.math.cast(std.meta.Tag(T), value) orelse return error.InvalidType) catch return error.InvalidType;
        },
        .bool => {
            if (lua.valueType(z.state, index) != .boolean) return Result(T).errStatic("expected boolean");
            return Result(T).ok(lua.toBoolean(z.state, index));
        },
        .int => {
            if (!lua.isInteger(z.state, index)) return Result(T).errStatic("expected integer");
            const value = lua.toInteger(z.state, index) orelse return Result(T).errStatic("expected integer");
            const cast_value = std.math.cast(T, value) orelse return Result(T).errStatic("integer out of range");
            return Result(T).ok(cast_value);
        },
        .float => return parseFloat(T, z.state, index),
        else => {},
    }

    if (comptime isStringValueType(T)) {
        if (lua.valueType(z.state, index) != .string) return Result(T).errStatic("expected string");
        return Result(T).ok(lua.toString(z.state, index) orelse return Result(T).errStatic("expected string"));
    }

    @compileError("unsupported decode type: " ++ @typeName(T));
}

/// Decodes a Lua table into a Zig struct by field name.
pub fn decodeStruct(table: Table, comptime T: type) ParseError!T {
    var result: T = undefined;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        @field(result, field.name) = (try table.get(field.name, field.type)).unwrap();
    }

    return result;
}

/// Decodes a Lua array table into a typed slice.
/// Allocates memory from the Zua allocator; caller must track for cleanup via cleanupDecodedValues.
fn decodeSlice(comptime T: type, z: *Zua, table: Table) ParseError!T {
    const ptr_info = @typeInfo(T).pointer;
    const Element = ptr_info.child;

    // Get array length from Lua table
    const index = switch (table.handle) {
        inline else => |idx| idx,
    };
    const len = lua.rawLen(z.state, index);

    // Allocate slice
    const slice = try z.allocator.alloc(Element, @intCast(len));
    errdefer z.allocator.free(slice);

    // Decode each element from the table
    for (0..@intCast(len)) |i| {
        slice[i] = (try table.get(@as(i64, @intCast(i + 1)), Element)).unwrap();
    }

    return slice;
}

/// Cleanup function that frees allocated slices in a decoded values tuple.
/// Call this after the callback returns to avoid memory leaks from decoded slices.
pub fn cleanupDecodedValues(z: *Zua, comptime types: anytype, values: ParseResult(types)) void {
    inline for (types, 0..) |T, index| {
        cleanupValue(z, T, values[index]);
    }
}

/// Recursively cleans up allocated slices, handling nested slice types.
fn cleanupValue(z: *Zua, comptime T: type, value: T) void {
    if (comptime @typeInfo(T) == .pointer) {
        const ptr_info = @typeInfo(T).pointer;
        if (ptr_info.size == .slice and !isStringValueType(T)) {
            const Element = ptr_info.child;

            // Recursively clean up each element if it's also a slice
            for (value) |elem| {
                cleanupValue(z, Element, elem);
            }

            // Free the outer slice
            z.allocator.free(value);
        }
    }
}

/// Pushes a Zig value onto the Lua stack.
///
/// The value is converted according to its compile-time type, including
/// custom encode hooks and table/object strategies.
pub fn pushValue(zua: *Zua, value: anytype) void {
    const T = @TypeOf(value);

    if (comptime isOptional(T)) {
        if (value) |unwrapped| {
            pushValue(zua, unwrapped);
        } else {
            lua.pushNil(zua.state);
        }
        return;
    }

    // Check for custom encode hook first
    if (comptime meta.hasEncodeHook(T)) {
        const encoded = T.ZUA_META.encode_hook(value);
        pushValue(zua, encoded);
        return;
    }

    if (T == Table) {
        const index = switch (value.handle) {
            inline else => |idx| idx,
        };
        lua.pushValue(zua.state, index);
        return;
    }

    if (comptime isStringValueType(T)) {
        lua.pushString(zua.state, value);
        return;
    }

    switch (comptime @typeInfo(T)) {
        .bool => {
            lua.pushBoolean(zua.state, value);
        },
        .int, .comptime_int => {
            lua.pushInteger(zua.state, std.math.cast(lua.Integer, value) orelse @panic("integer value out of range for Lua"));
        },
        .float, .comptime_float => {
            lua.pushNumber(zua.state, @as(lua.Number, value));
        },
        .@"enum" => {
            lua.pushInteger(zua.state, @intFromEnum(value));
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => {
                const Pointee = ptr_info.child;

                // Handle *const [N]T arrays by treating as slices
                if (@typeInfo(Pointee) == .array) {
                    const arr_info = @typeInfo(Pointee).array;
                    const slice: []const arr_info.child = value[0..arr_info.len];
                    pushValue(zua, slice);
                    return;
                }

                if (@typeInfo(Pointee) == .@"struct" or @typeInfo(Pointee) == .@"union") {
                    const strategy = comptime meta.strategyOf(Pointee);

                    if (strategy == .object) {
                        @compileError("cannot push *T where T is .object: the metatable would be lost. Return T by value instead");
                    }

                    if (strategy == .zig_ptr) {
                        lua.pushLightUserdata(zua.state, value);
                        return;
                    }

                    @compileError("cannot push pointer to .table type");
                }

                @compileError("unsupported push type: " ++ @typeName(T));
            },
            .slice => {
                if (comptime isStringValueType(T)) {
                    @compileError("unsupported push type: " ++ @typeName(T));
                }

                lua.createTable(zua.state, std.math.cast(i32, value.len) orelse @panic("slice too large"), 0);
                const nested = Table.fromStack(zua, -1);
                fillTable(nested, value);
                return;
            },
            else => @compileError("unsupported push type: " ++ @typeName(T)),
        },
        .@"struct" => {
            const strategy = comptime meta.strategyOf(T);

            if (strategy == .object) {
                const mt = @import("metatable.zig");
                const ptr: *T = @ptrCast(@alignCast(lua.newUserdata(zua.state, @sizeOf(T))));
                ptr.* = value;
                mt.attachMetatable(zua, T);
                return;
            }

            if (strategy == .zig_ptr) {
                @compileError("cannot push .zig_ptr type by value: push a *T instead");
            }

            // .table strategy (including anonymous structs)
            lua.createTable(zua.state, inferArrayCapacity(value), inferRecordCapacity(value));
            const nested = Table.fromStack(zua, -1);
            fillTable(nested, value);

            const mt = @import("metatable.zig");
            mt.attachMetatable(zua, T);
        },
        .@"union" => {
            const strategy = comptime meta.strategyOf(T);

            if (strategy == .object) {
                const mt = @import("metatable.zig");
                const ptr: *T = @ptrCast(@alignCast(lua.newUserdata(zua.state, @sizeOf(T))));
                ptr.* = value;
                mt.attachMetatable(zua, T);
                return;
            }

            if (strategy == .zig_ptr) {
                @compileError("cannot push .zig_ptr union by value: push a *T instead");
            }

            lua.createTable(zua.state, 0, 1);
            const table = Table.fromStack(zua, -1);
            switch (value) {
                inline else => |v, tag| {
                    table.set(@tagName(tag), v);
                },
            }

            const mt = @import("metatable.zig");
            mt.attachMetatable(zua, T);
        },
        .array => {
            lua.createTable(zua.state, inferArrayCapacity(value), 0);
            const nested = Table.fromStack(zua, -1);
            fillTable(nested, value);
        },
        else => @compileError("unsupported push type: " ++ @typeName(T)),
    }
}

/// Recursively fills a Lua table from a Zig struct, array, tuple, or slice.
pub fn fillTable(table: Table, value: anytype) void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.is_tuple) {
                inline for (value, 0..) |item, index| {
                    table.set(index + 1, item);
                }
                return;
            }

            inline for (info.fields) |field| {
                table.set(field.name, @field(value, field.name));
            }
        },
        .array => {
            for (value, 0..) |item, index| {
                table.set(index + 1, item);
            }
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (comptime isStringValueType(T)) {
                    @compileError("string-like values must be stored as Lua strings, not table fills");
                }

                for (value, 0..) |item, index| {
                    table.set(index + 1, item);
                }
            },
            else => @compileError("unsupported table fill type: " ++ @typeName(T)),
        },
        else => @compileError("unsupported table fill type: " ++ @typeName(T)),
    }
}

/// Infers the array portion capacity for a Lua table representation of `value`.
pub fn inferArrayCapacity(value: anytype) i32 {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .@"struct" => |info| if (info.is_tuple) @intCast(info.fields.len) else 0,
        .array => @intCast(value.len),
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (comptime isStringValueType(T))
                @compileError("string-like values are not table-convertible")
            else
                std.math.cast(i32, value.len) orelse @panic("slice too large for Lua table"),
            else => @compileError("unsupported table conversion type: " ++ @typeName(T)),
        },
        else => @compileError("unsupported table conversion type: " ++ @typeName(T)),
    };
}

/// Infers the record portion capacity for a Lua table representation of `value`.
pub fn inferRecordCapacity(value: anytype) i32 {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .@"struct" => |info| if (info.is_tuple) 0 else @intCast(info.fields.len),
        .array, .pointer => 0,
        else => @compileError("unsupported table conversion type: " ++ @typeName(T)),
    };
}

fn parseInteger(comptime T: type, state: *lua.State, index: lua.StackIndex) ParseError!T {
    if (!lua.isInteger(state, index)) return error.InvalidType;

    const value = lua.toInteger(state, index) orelse return error.InvalidType;
    return std.math.cast(T, value) orelse error.InvalidType;
}

fn parseFloat(comptime T: type, state: *lua.State, index: lua.StackIndex) ParseError!Result(T) {
    if (!lua.isNumber(state, index)) return error.InvalidType;

    const value = lua.toNumber(state, index) orelse return error.InvalidType;
    return Result(T).ok(@floatCast(value));
}

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn optionalChild(comptime T: type) type {
    return @typeInfo(T).optional.child;
}

fn isStringValueType(comptime T: type) bool {
    if (T == []const u8 or T == [:0]const u8) return true;

    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .one => @typeInfo(pointer.child) == .array and @typeInfo(@typeInfo(pointer.child).array.child) == .int,
            .slice => pointer.child == u8 and pointer.is_const,
            else => false,
        },
        else => false,
    };
}

fn isTableConvertibleType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => true,
        .array => true,
        .pointer => |pointer| pointer.size == .slice and !isStringValueType(T),
        else => false,
    };
}

test "pushValue supports slices of object types" {
    const zua_mod = @import("zua.zig");

    const Item = struct {
        const Self = @This();

        pub const ZUA_META = meta.Object(Self, .{
            .getName = getName,
        });

        name: []const u8,

        fn getName(self: *Self) @import("result.zig").Result([]const u8) {
            return @import("result.zig").Result([]const u8).ok(self.name);
        }
    };

    const z = try zua_mod.Zua.init(std.testing.allocator, std.testing.io);
    defer z.deinit();

    const items = [_]Item{
        .{ .name = "one" },
        .{ .name = "two" },
    };

    pushValue(z, items[0..items.len]);
    const table = Table.fromStack(z, -1);
    defer table.pop();

    const first = (try table.get(1, Item)).unwrap();
    const second = (try table.get(2, Item)).unwrap();

    try std.testing.expectEqualStrings("one", first.name);
    try std.testing.expectEqualStrings("two", second.name);
}
