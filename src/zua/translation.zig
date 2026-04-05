const std = @import("std");
const lua = @import("../lua/lua.zig");
const meta = @import("meta.zig");

const Zua = @import("zua.zig").Zua;
const Table = @import("table.zig").Table;
const Strategy = meta.Strategy;

/// Errors returned by typed value decoding and parsing.
pub const ParseError = error{
    InvalidArity,
    InvalidType,
    OutOfMemory,
};

/// Ownership mode used when decoding tables into `zua.Table` handles.
pub const TableOwnership = enum {
    owned,
    borrowed,
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
    table_ownership: TableOwnership,
) ParseError!ParseResult(types) {
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
                    values[index] = try decodeValue(
                        z,
                        stack_index,
                        optionalChild(T),
                        table_ownership,
                    );
                }
            }
        } else {
            if (index >= value_count) return error.InvalidArity;

            const stack_index = start_index + @as(lua.StackIndex, @intCast(index));
            values[index] = try decodeValue(
                z,
                stack_index,
                T,
                table_ownership,
            );
        }
    }

    return values;
}

/// Decodes a Lua value from the stack at `index` into type `T`.
/// Supports strings, numbers, booleans, tables, userdata, pointers, and optional values.
pub fn decodeValue(
    z: *Zua,
    index: lua.StackIndex,
    comptime T: type,
    table_ownership: TableOwnership,
) ParseError!T {
    if (comptime isOptional(T)) {
        if (lua.valueType(z.state, index) == .nil) return null;
        return try decodeValue(z, index, optionalChild(T), table_ownership);
    }

    // Check for custom decode hook first
    if (comptime meta.hasDecodeHook(T)) {
        const kind = lua.valueType(z.state, index);
        return T.ZUA_META.decode_hook(z, index, kind) catch return error.InvalidType;
    }

    switch (comptime @typeInfo(T)) {
        .pointer => |ptr_info| {
            if (ptr_info.size == .one) {
                const Pointee = ptr_info.child;

                if (@typeInfo(Pointee) == .@"struct") {
                    const strategy = comptime meta.strategyOf(Pointee);

                    if (strategy == .object) {
                        if (lua.valueType(z.state, index) != .userdata) return error.InvalidType;
                        const raw = lua.toUserdata(z.state, index) orelse return error.InvalidType;
                        return @ptrCast(@alignCast(raw));
                    }

                    if (strategy == .zig_ptr) {
                        if (lua.valueType(z.state, index) != .light_userdata) return error.InvalidType;
                        const raw = lua.toLightUserdata(z.state, index) orelse return error.InvalidType;
                        return @ptrCast(@alignCast(raw));
                    }

                    return error.InvalidType;
                }
            }

            // Handle non-string slices: decode from Lua array table
            if (comptime ptr_info.size == .slice and !isStringValueType(T)) {
                if (lua.valueType(z.state, index) != .table) return error.InvalidType;
                const table = Table.fromBorrowed(z, index);
                return try decodeSlice(T, z, table);
            }

            // Non-single or non-struct pointer: fall through to string/slice checks below.
        },
        .@"struct" => {
            const strategy = comptime meta.strategyOf(T);

            if (strategy == .object) {
                if (lua.valueType(z.state, index) != .userdata) return error.InvalidType;
                const raw = lua.toUserdata(z.state, index) orelse return error.InvalidType;
                const typed: *T = @ptrCast(@alignCast(raw));
                return typed.*;
            }

            if (strategy == .zig_ptr) {
                if (lua.valueType(z.state, index) != .light_userdata) return error.InvalidType;
                const raw = lua.toLightUserdata(z.state, index) orelse return error.InvalidType;
                const typed: *T = @ptrCast(@alignCast(raw));
                return typed.*;
            }

            if (T == Table) {
                if (lua.valueType(z.state, index) != .table) return error.InvalidType;
                return switch (table_ownership) {
                    .owned => Table.fromStack(z, index),
                    .borrowed => Table.fromBorrowed(z, index),
                };
            }

            // .table strategy: decode by field name from a Lua table.
            if (lua.valueType(z.state, index) != .table) return error.InvalidType;
            const table = Table.fromBorrowed(z, index);
            return decodeStruct(table, T);
        },
        .@"enum" => {
            if (lua.valueType(z.state, index) != .integer) return error.InvalidType;
            const value = lua.toInteger(z.state, index) orelse return error.InvalidType;
            return std.meta.intToEnum(T, std.math.cast(std.meta.Tag(T), value) orelse return error.InvalidType) catch return error.InvalidType;
        },
        .bool => {
            if (lua.valueType(z.state, index) != .boolean) return error.InvalidType;
            return lua.toBoolean(z.state, index);
        },
        .int => return parseInteger(T, z.state, index),
        .float => return parseFloat(T, z.state, index),
        else => {},
    }

    if (comptime isStringValueType(T)) {
        if (lua.valueType(z.state, index) != .string) return error.InvalidType;
        return lua.toString(z.state, index) orelse error.InvalidType;
    }

    @compileError("unsupported decode type: " ++ @typeName(T));
}

/// Decodes a Lua table into a Zig struct by field name.
pub fn decodeStruct(table: Table, comptime T: type) ParseError!T {
    var result: T = undefined;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        @field(result, field.name) = try table.get(field.name, field.type);
    }

    return result;
}

/// Decodes a Lua array table into a typed slice.
/// Allocates memory from the Zua allocator; caller must track for cleanup via cleanupDecodedValues.
fn decodeSlice(comptime T: type, z: *Zua, table: Table) ParseError!T {
    const ptr_info = @typeInfo(T).pointer;
    const Element = ptr_info.child;

    // Get array length from Lua table
    const len = lua.rawLen(z.state, table.index);

    // Allocate slice
    const slice = try z.allocator.alloc(Element, @intCast(len));
    errdefer z.allocator.free(slice);

    // Decode each element from the table
    for (0..@intCast(len)) |i| {
        slice[i] = try table.get(@as(i64, @intCast(i + 1)), Element);
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
        lua.pushValue(zua.state, value.index);
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
        .pointer => |ptr_info| {
            if (ptr_info.size == .one) {
                const Pointee = ptr_info.child;

                if (@typeInfo(Pointee) == .@"struct") {
                    const strategy = comptime meta.strategyOf(Pointee);

                    if (strategy == .object) {
                        @compileError("cannot push *T where T is .object: the metatable would be lost. Return T by value instead");
                    }

                    if (strategy == .zig_ptr) {
                        lua.pushLightUserdata(zua.state, value);
                        return;
                    }

                    // .table single pointer: fall through to the compile error below.
                    @compileError("cannot push pointer to .table type");
                }
            }

            if (ptr_info.size == .slice and !isStringValueType(T)) {
                lua.createTable(zua.state, std.math.cast(i32, value.len) orelse @panic("slice too large"), 0);
                const nested = Table.fromStack(zua, -1);
                fillTable(nested, value);
                return;
            }

            @compileError("unsupported push type: " ++ @typeName(T));
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

fn parseFloat(comptime T: type, state: *lua.State, index: lua.StackIndex) ParseError!T {
    if (!lua.isNumber(state, index)) return error.InvalidType;

    const value = lua.toNumber(state, index) orelse return error.InvalidType;
    return @floatCast(value);
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
