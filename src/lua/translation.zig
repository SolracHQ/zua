const std = @import("std");
const lua = @import("lua.zig");

/// Translation helpers for converting between Zig values and Lua stack values.
///
/// These helpers are used by zua to decode Lua arguments into typed Zig values,
/// encode Zig values back onto the Lua stack, and build Lua tables from Zig
/// structs, arrays, tuples, and slices.
pub const ParseError = error{
    InvalidArity,
    InvalidType,
};

/// Ownership model for decoded Lua table handles.
///
/// `owned` returns a table handle that owns the stack slot and may pop it later.
/// `borrowed` returns a handle that refers to an existing stack slot without
/// taking ownership.
pub const TableOwnership = enum {
    owned,
    borrowed,
};

pub fn ParseResult(comptime types: anytype) type {
    comptime var field_types: [types.len]type = undefined;

    inline for (types, 0..) |T, index| {
        field_types[index] = T;
    }

    return std.meta.Tuple(&field_types);
}

/// Parses a contiguous range of values from the Lua stack into a typed tuple.
///
/// `TableType` is the concrete Lua table wrapper type used for nested table values.
/// `types` describes the expected Zig types for each decoded value.
/// `table_ownership` controls whether nested table handles are owned or borrowed.
///
/// Returns `ParseError.InvalidArity` when the number of values is outside the
/// expected range, or `ParseError.InvalidType` when a value cannot be decoded.
pub fn parseTuple(
    comptime TableType: type,
    state: *lua.State,
    allocator: std.mem.Allocator,
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

                if (lua.valueType(state, stack_index) == .nil) {
                    values[index] = null;
                } else {
                    values[index] = try decodeValue(
                        TableType,
                        state,
                        allocator,
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
                TableType,
                state,
                allocator,
                stack_index,
                T,
                table_ownership,
            );
        }
    }

    return values;
}

/// Decodes a single Lua stack value into the requested Zig type.
///
/// Supports optional values, boolean, integer, float, string, table handles, and
/// nested struct decoding from borrowed Lua tables.
pub fn decodeValue(
    comptime TableType: type,
    state: *lua.State,
    allocator: std.mem.Allocator,
    index: lua.StackIndex,
    comptime T: type,
    table_ownership: TableOwnership,
) ParseError!T {
    if (@typeInfo(T) == .optional) {
        if (lua.valueType(state, index) == .nil) return null;
        return try decodeValue(TableType, state, allocator, index, optionalChild(T), table_ownership);
    }

    if (T == TableType) {
        if (lua.valueType(state, index) != .table) return error.InvalidType;

        return switch (table_ownership) {
            .owned => TableType.fromStack(state, allocator, index),
            .borrowed => TableType.fromBorrowed(state, allocator, index),
        };
    }

    if (@typeInfo(T) == .@"struct") {
        if (lua.valueType(state, index) != .table) return error.InvalidType;

        const table = TableType.fromBorrowed(state, allocator, index);
        return decodeStruct(TableType, table, T);
    }

    if (T == bool) {
        if (lua.valueType(state, index) != .boolean) return error.InvalidType;
        return lua.toBoolean(state, index);
    }

    if (T == []const u8 or T == [:0]const u8) {
        if (lua.valueType(state, index) != .string) return error.InvalidType;
        return lua.toString(state, index) orelse error.InvalidType;
    }

    return switch (@typeInfo(T)) {
        .int => parseInteger(T, state, index),
        .float => parseFloat(T, state, index),
        else => @compileError("unsupported decode type: " ++ @typeName(T)),
    };
}

/// Decodes a borrowed Lua table into a Zig struct by reading fields by name.
///
/// This is used for nested struct decoding when the expected type is a Zig
/// struct and the Lua value is a table.
pub fn decodeStruct(comptime TableType: type, table: TableType, comptime T: type) ParseError!T {
    var result: T = undefined;

    inline for (@typeInfo(T).@"struct".fields) |field| {
        @field(result, field.name) = try table.get(field.name, field.type);
    }

    return result;
}

/// Pushes a Zig value onto the Lua stack.
///
/// Nested structs, arrays, tuples, and slices are converted into Lua tables.
/// Strings, numbers, and booleans are pushed as the corresponding Lua values.
pub fn pushValue(comptime TableType: type, state: *lua.State, allocator: std.mem.Allocator, value: anytype) void {
    const T = @TypeOf(value);

    if (@typeInfo(T) == .optional) {
        if (value) |unwrapped| {
            pushValue(TableType, state, allocator, unwrapped);
        } else {
            lua.pushNil(state);
        }
        return;
    }

    if (T == TableType) {
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
        lua.createTable(state, inferArrayCapacity(value), inferRecordCapacity(value));
        const nested = TableType.fromStack(state, allocator, -1);
        fillTable(TableType, nested, value);
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

/// Fills a Lua table from a Zig value that can be table-converted.
///
/// Structs are converted into string-keyed records, tuples into array values, and
/// slices/arrays into integer-keyed arrays. Nested convertible values are
/// converted recursively.
pub fn fillTable(comptime TableType: type, table: TableType, value: anytype) void {
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

/// Returns an array-part capacity hint for table creation based on the value.
///
/// This is used by `Zua.tableFrom` to preallocate Lua table array storage when
/// converting arrays, tuples, and slices.
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

/// Returns a record-part capacity hint for table creation based on the value.
///
/// Structs with named fields reserve capacity for record fields. Tuples, arrays,
/// and slices do not contribute record-part capacity.
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
            .one => @typeInfo(pointer.child) == .array,
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
