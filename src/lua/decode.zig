const std = @import("std");
const lua = @import("lua.zig");
const Table = @import("table.zig").Table;

/// Error type for decoding Lua stack values into Zig types.
/// - `InvalidArity`: wrong number of values on stack (e.g., expected 2 args but got 1)
/// - `InvalidType`: value at stack position is not the expected Zig type
/// - `OutOfRange`: numeric value cannot fit in the target integer type
pub const ParseError = error{
    InvalidArity,
    InvalidType,
    OutOfRange,
};

/// Controls whether decoded Tables are pushed as owned or borrowed.
/// - `owned`: table is pushed to the stack and tracked by the handle
/// - `borrowed`: table is not pushed; handle references an existing stack position
pub const TableOwnership = enum {
    owned,
    borrowed,
};

/// Constructs a tuple type from a comptime type list.
/// Used internally to define the return type of `parseTuple` and Result value storage.
/// Example: `ParseResult(.{i32, bool})` yields `std.meta.Tuple(&[_]type{i32, bool})`.
pub fn ParseResult(comptime types: anytype) type {
    comptime var field_types: [types.len]type = undefined;

    inline for (types, 0..) |T, index| {
        field_types[index] = T;
    }

    return std.meta.Tuple(&field_types);
}

/// Decodes a sequence of Lua stack values into a typed tuple.
///
/// Arguments:
/// - `state`: Lua state
/// - `allocator`: used for Table allocations if `table_ownership == .owned`
/// - `start_index`: absolute stack position of the first value
/// - `value_count`: number of values to decode (must equal `types.len`)
/// - `types`: comptime tuple of target Zig types (e.g., `.{i32, bool, []const u8}`)
/// - `table_ownership`: whether to push decoded tables or borrow existing ones
///
/// Returns: tuple of decoded and converted values, or error if arity/type mismatch.
pub fn parseTuple(
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

    if (value_count < min_arity or value_count > types.len)
        return error.InvalidArity;

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
                    values[index] =
                        try decodeValue(
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

            values[index] =
                try decodeValue(
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

/// Decodes a single Lua stack value into a Zig type.
///
/// Supported types:
/// - `bool`, `i32`, `i64`, `f32`, `f64`: numeric and boolean values
/// - `[]const u8`, `[:0]const u8`: Lua strings
/// - `Table`: Lua tables (ownership controlled by `table_ownership`)
///
/// Other types will produce a compile error.
/// Returns error if the stack value is not the expected type or out of range.
pub fn decodeValue(
    state: *lua.State,
    allocator: std.mem.Allocator,
    index: lua.StackIndex,
    comptime T: type,
    table_ownership: TableOwnership,
) ParseError!T {
    if (T == Table) {
        if (lua.valueType(state, index) != .table) return error.InvalidType;

        return switch (table_ownership) {
            .owned => Table.fromStack(state, allocator, index),
            .borrowed => Table.fromBorrowed(state, allocator, index),
        };
    }

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

    return switch (@typeInfo(T)) {
        .int => parseInteger(T, state, index),
        .float => parseFloat(T, state, index),
        else => @compileError("unsupported stack decode type: " ++ @typeName(T)),
    };
}

// Numeric helpers

fn parseInteger(comptime T: type, state: *lua.State, index: lua.StackIndex) ParseError!T {
    if (!lua.isInteger(state, index)) return error.InvalidType;

    const value = lua.toInteger(state, index) orelse return error.InvalidType;
    return std.math.cast(T, value) orelse error.OutOfRange;
}

fn parseFloat(comptime T: type, state: *lua.State, index: lua.StackIndex) ParseError!T {
    if (!lua.isNumber(state, index)) return error.InvalidType;

    const value = lua.toNumber(state, index) orelse return error.InvalidType;
    return @floatCast(value);
}

// Optional type helpers

fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

fn optionalChild(comptime T: type) type {
    return @typeInfo(T).optional.child;
}
