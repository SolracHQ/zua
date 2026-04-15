//! Decoding utilities for translating Lua stack values into typed Zig values.
//!
//! This module provides the core `Decoder` interface used by the Zua metadata
//! pipeline. It supports optional arguments, custom decode hooks, host pointer
//! handling for userdata and light userdata, and the low-level conversion of
//! Lua primitives into Zig values.

const std = @import("std");
const lua = @import("../../lua/lua.zig");

const Table = @import("../handlers/table.zig");
const Function = @import("../handlers/function.zig");
const Userdata = @import("../handlers/userdata.zig").Userdata;
const Context = @import("../state/context.zig");
const State = @import("../state/state.zig");
const Meta = @import("../meta.zig");

const Fn = @import("../typed/fn.zig").Fn;
const Object = @import("../typed/object.zig").Object;

const Mapper = @import("mapper.zig");

pub const Decoder = @This();

pub const Primitive = Mapper.Primitive;

/// Variadic Lua arguments captured as a slice of primitives.
///
/// Declare `VarArgs` as the last parameter of a callback to receive all Lua
/// arguments that were not matched by preceding parameters. The slice is
/// allocated from the context arena and is valid for the duration of the call.
///
/// Example:
/// ```zig
/// fn log(prefix: []const u8, rest: zua.Decoder.VarArgs) void {
///     for (rest.args) |arg| {
///         // inspect each arg via the Primitive union
///         _ = arg;
///     }
/// }
/// ```
pub const VarArgs = struct {
    args: []Primitive,
};

/// Tuple type used to hold decoded arguments.
///
/// Accepts either a single type or a tuple of types; for a single type it
/// returns that type directly.
///
/// Arguments:
/// - types: The compile-time argument type list or single type to represent.
///
/// Returns:
/// - type: A tuple type containing the decoded argument types, or the original
///   type when a single argument is provided.
pub fn ParseResult(comptime types: anytype) type {
    const Ty = @TypeOf(types);
    if (Ty == type) return types;

    comptime var field_types: [types.len]type = undefined;
    inline for (types, 0..) |T, i| field_types[i] = T;
    return @Tuple(&field_types);
}

/// Parses a sequence of Lua stack values into a typed Zig tuple.
///
/// Supports optional trailing arguments. This is used by the Lua callback
/// wrapper to decode function arguments before the callback is invoked.
///
/// Arguments:
/// - ctx: The current call context used for decoding and error reporting.
/// - start_index: The first Lua stack index to decode from.
/// - value_count: The number of Lua values available to decode.
/// - types: The compile-time list of expected target types.
///
/// Returns:
/// - `ParseResult(types)`: The decoded tuple or single value on success.
/// - `error.InvalidArity`: When the provided values do not match the expected shape.
///
/// Example:
/// ```zig
/// const args = try Mapper.Decoder.parseTuple(ctx, 1, lua.getTop(ctx.state.luaState), .{i32, []const u8});
/// ```
pub fn parseTuple(
    ctx: *Context,
    start_index: lua.StackIndex,
    value_count: lua.StackCount,
    comptime types: anytype,
) !ParseResult(types) {
    if (@TypeOf(types) == type) {
        return parseSingle(ctx, start_index, value_count, types);
    }
    return parseMulti(ctx, start_index, value_count, types);
}

/// Parses a single Lua stack value into a Zig type.
///
/// This helper is used when the expected target type is not a tuple. It
/// supports optional values and enforces exact arity for non-optional targets.
fn parseSingle(
    ctx: *Context,
    start_index: lua.StackIndex,
    value_count: lua.StackCount,
    comptime T: type,
) !T {
    const is_opt = comptime Mapper.isOptional(T);
    const ChildT = if (comptime is_opt) Mapper.optionalChild(T) else T;

    if (value_count == 0) {
        if (is_opt) return null;
        return ctx.failTyped(T, "invalid arity");
    }

    if (value_count > 1) return ctx.failTyped(T, "invalid arity");

    if (is_opt and value_count == 0) return null;

    return decodeAt(ctx, start_index, ChildT);
}

/// Parses multiple Lua stack values into a tuple of Zig types.
///
/// This helper validates optional arguments, enforces minimum and maximum arity,
/// and decodes each position in turn.
fn parseMulti(
    ctx: *Context,
    start_index: lua.StackIndex,
    value_count: lua.StackCount,
    comptime types: anytype,
) !ParseResult(types) {
    comptime var min_arity: usize = 0;
    inline for (types) |T| {
        if (comptime !Mapper.isOptional(T)) min_arity += 1;
    }

    if (value_count < min_arity or value_count > types.len) {
        try ctx.fail("invalid arity");
    }

    var values: ParseResult(types) = undefined;

    inline for (types, 0..) |T, i| {
        const stack_index = start_index + @as(lua.StackIndex, @intCast(i));

        if (comptime Mapper.isOptional(T)) {
            if (i >= value_count) {
                values[i] = null;
            } else {
                values[i] = try decodeAt(ctx, stack_index, T);
            }
        } else {
            if (i >= value_count) try ctx.fail("invalid arity");
            values[i] = try decodeAt(ctx, stack_index, T);
        }
    }

    return values;
}

/// Reads a Lua stack value at `index` into a `Primitive` variant.
///
/// This helper extracts the Lua value from the stack without performing the
/// final type-directed decode. It preserves borrowed handles for tables and
/// functions, which remain valid only for the lifetime of the current stack
/// frame.
pub fn buildPrimitive(z: *State, index: lua.StackIndex) !Primitive {
    return switch (lua.valueType(z.luaState, index)) {
        .boolean => .{ .boolean = lua.toBoolean(z.luaState, index) },
        .number => if (lua.isInteger(z.luaState, index))
            .{ .integer = lua.toInteger(z.luaState, index) orelse return error.InvalidType }
        else
            .{ .float = lua.toNumber(z.luaState, index) orelse return error.InvalidType },
        .string => .{ .string = lua.toString(z.luaState, index) orelse return error.InvalidType },
        .table => .{ .table = Table.fromBorrowed(z, index) },
        .function => .{ .function = Function.fromBorrowed(z, index) },
        .userdata => .{ .userdata = Userdata.fromBorrowed(z, index) },
        .light_userdata => .{ .light_userdata = lua.toLightUserdata(z.luaState, index) orelse return error.InvalidType },
        .nil, .none => .nil,
        else => error.InvalidType,
    };
}

/// Decodes a raw pointer from a Primitive using the host-object strategy of `T`.
///
/// Accepts both single-pointer and struct targets; `T` must carry a `.object`
/// or `.ptr` meta strategy.
fn decodeHostPtr(comptime T: type, prim: Primitive, ctx: *Context) !T {
    const Pointee = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
    const strategy = comptime Meta.getMeta(Pointee).strategy;

    switch (strategy) {
        .object => {
            const raw = switch (prim) {
                .userdata => |p| p,
                else => return ctx.failTyped(T, "expected userdata"),
            };
            return Object(Pointee).from(raw).get();
        },
        .ptr => {
            const raw = switch (prim) {
                .light_userdata => |p| p,
                else => return ctx.failTyped(T, "expected light userdata"),
            };
            return @ptrCast(@alignCast(raw));
        },
        else => return ctx.failTyped(T, "expected object or pointer strategy"),
    }
}

fn isHandlerType(comptime T: type) bool {
    return T == Table or T == Function or T == Userdata;
}

fn handlerExpectedTypeName(comptime T: type) []const u8 {
    return if (comptime T == Table) "table" else if (comptime T == Function) "function" else "userdata";
}

/// Decodes a stack value at `index` into a Zig type `T`.
///
/// This is the index-based entry point. It handles optional nil checks,
/// builds the `Primitive`, and delegates to `decodeValue`.
///
/// Resolution order:
///   1. Optional nil → return null
///   2. `buildPrimitive` at `index`
///   3. `decodeValue` for type-directed dispatch
pub fn decodeAt(ctx: *Context, index: lua.StackIndex, comptime T: type) !T {
    const prim = try buildPrimitive(ctx.state, index);
    return decodeValue(ctx, prim, T);
}

/// Decodes a `Primitive` into a Zig type `T`.
///
/// This is the primitive-based entry point used by custom decode hooks,
/// `VarArgs` inspection, and any code that already holds a `Primitive`.
/// Does not handle optional types — use `decodeAt` when working with an
/// index and optional targets.
///
/// Resolution order:
///   1. Custom decode hook (struct / union / enum only)
///   2. Type-directed dispatch
pub fn decodeValue(ctx: *Context, prim: Primitive, comptime T: type) !T {
    if (comptime Mapper.isOptional(T)) {
        if (prim == .nil) return null;
        return try decodeValue(ctx, prim, Mapper.optionalChild(T));
    }

    if (comptime T == Primitive) return prim;

    if (comptime T == void) {
        if (prim != .nil) return ctx.failTyped(T, "expected nil for void type");
        return;
    }

    if (prim == .nil) return ctx.failTyped(T, "expected value, got nil");

    if (comptime isHandlerType(T)) {
        if (comptime T == Table) {
            return switch (prim) {
                .table => |t| t,
                else => ctx.failTyped(T, "expected table"),
            };
        }

        if (comptime T == Function) {
            return switch (prim) {
                .function => |f| f,
                else => ctx.failTyped(T, "expected function"),
            };
        }

        return switch (prim) {
            .userdata => |u| u,
            else => ctx.failTyped(T, "expected userdata"),
        };
    }

    if (comptime @typeInfo(T) == .@"struct" or @typeInfo(T) == .@"union" or @typeInfo(T) == .@"enum") {
        if (comptime Meta.getMeta(T).decode_hook) |hook| {
            return try hook(ctx, prim);
        }
    }

    return switch (comptime @typeInfo(T)) {
        .pointer => |ptr_info| decodePointer(T, ptr_info, prim, ctx),
        .@"struct" => decodeStructValue(T, prim, ctx),
        .@"union" => decodeUnionValue(T, prim, ctx),
        .@"enum" => decodeEnum(T, prim, ctx),
        .bool => switch (prim) {
            .boolean => |b| b,
            else => ctx.failTyped(T, "expected boolean"),
        },
        .int => switch (prim) {
            .integer => |i| std.math.cast(T, i) orelse return ctx.failTyped(T, "integer out of range"),
            else => ctx.failTyped(T, "expected integer"),
        },
        .float => switch (prim) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => ctx.failTyped(T, "expected float"),
        },
        else => if (comptime Mapper.isStringValueType(T))
            switch (prim) {
                .string => |s| s,
                else => ctx.failTyped(T, "expected string"),
            }
        else
            @compileError("unsupported decode type: " ++ @typeName(T)),
    };
}

/// Builds a `VarArgs` value from `count` consecutive Lua stack slots starting
/// at `start_index`. The resulting slice is allocated from the context arena.
pub fn buildVarArgs(ctx: *Context, start_index: lua.StackIndex, count: usize) !VarArgs {
    const args = try ctx.arena().alloc(Primitive, count);
    for (0..count) |i| {
        args[i] = try buildPrimitive(ctx.state, start_index + @as(lua.StackIndex, @intCast(i)));
    }
    return .{ .args = args };
}

/// Decodes a pointer-like target from a Lua primitive.
///
/// Supports both string pointer values and slice targets. Host pointer targets
/// are delegated to `decodeHostPtr` when the pointee is an object or union.
fn decodePointer(
    comptime T: type,
    comptime ptr_info: std.builtin.Type.Pointer,
    prim: Primitive,
    ctx: *Context,
) !T {
    if (ptr_info.size == .one) {
        const Pointee = ptr_info.child;
        if (comptime @typeInfo(Pointee) == .@"struct" or @typeInfo(Pointee) == .@"union") {
            return decodeHostPtr(T, prim, ctx);
        }
    }

    if (comptime ptr_info.size == .slice and !Mapper.isStringValueType(T)) {
        const table = switch (prim) {
            .table => |t| t,
            else => return ctx.failTyped(T, "expected table"),
        };
        return decodeSlice(T, ctx, table);
    }

    if (comptime Mapper.isStringValueType(T)) {
        return switch (prim) {
            .string => |s| s,
            else => ctx.failTyped(T, "expected string"),
        };
    }

    @compileError("unsupported pointer type: " ++ @typeName(T));
}

/// Decodes a non-pointer Zig struct value from a Lua primitive.
///
/// For `.object` or `.ptr` strategies the value is decoded as a host pointer.
/// Otherwise, regular structs are decoded from Lua tables.
fn decodeStructValue(comptime T: type, prim: Primitive, ctx: *Context) !T {
    const strategy = comptime Meta.getMeta(T).strategy;

    if (strategy == .object or strategy == .ptr) {
        return decodeHostPtr(T, prim, ctx);
    }

    if (T == Table) {
        return switch (prim) {
            .table => |t| t,
            else => ctx.failTyped(T, "expected table"),
        };
    }

    if (comptime T == Function) {
        return switch (prim) {
            .function => |f| f,
            else => ctx.failTyped(T, "expected function"),
        };
    }

    const table = switch (prim) {
        .table => |t| t,
        else => return ctx.failTyped(T, "expected table"),
    };
    return decodeStruct(ctx, table, T);
}

/// Decodes a non-pointer Zig union value from a Lua primitive.
///
/// Objects and pointers are decoded via host pointer strategy. Other unions are
/// decoded from Lua tables by matching the active variant key.
fn decodeUnionValue(comptime T: type, prim: Primitive, ctx: *Context) !T {
    const strategy = comptime Meta.getMeta(T).strategy;

    if (strategy == .object or strategy == .ptr) {
        return decodeHostPtr(T, prim, ctx);
    }

    const table = switch (prim) {
        .table => |t| t,
        else => return ctx.failTyped(T, "expected table"),
    };
    return decodeUnion(ctx, table, T);
}

/// Decodes a Zig enum value from a Lua primitive.
///
/// Only integer primitives are accepted, and the value is validated against the
/// enum's valid tag range.
fn decodeEnum(comptime T: type, prim: Primitive, ctx: *Context) !T {
    const value = switch (prim) {
        .integer => |v| v,
        else => return ctx.failTyped(T, "expected integer"),
    };
    const tag = std.math.cast(std.meta.Tag(T), value) orelse
        return ctx.failTyped(T, "integer out of range");
    return std.meta.intToEnum(T, tag) catch ctx.failTyped(T, "invalid enum value");
}

/// Decodes a Lua table into a Zig struct by field name.
///
/// This helper is used for non-`object` struct types that are represented as
/// Lua tables. It reads each field from the Lua table and assigns it to the
/// corresponding struct field.
///
/// Arguments:
/// - ctx: The current call context used for error reporting.
/// - table: The borrowed Lua table handle.
/// - T: The target Zig struct type.
///
/// Returns:
/// - `T`: The decoded struct on success.
/// - `error.Failed`: When a required field is missing or cannot be decoded.
pub fn decodeStruct(ctx: *Context, table: Table, comptime T: type) !T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        @field(result, field.name) = try table.get(ctx, field.name, field.type);
    }
    return result;
}

/// Decodes a Lua table into a tagged union by matching exactly one field key.
///
/// For tagged unions the table must contain exactly one key that corresponds to
/// a union variant name. If multiple variant keys are present, decoding fails.
///
/// Arguments:
/// - ctx: The current call context used for error reporting.
/// - table: The borrowed Lua table handle.
/// - T: The target Zig tagged union type.
///
/// Returns:
/// - `T`: The decoded union value on success.
/// - `error.Failed`: When no matching variant is found or more than one variant is present.
pub fn decodeUnion(ctx: *Context, table: Table, comptime T: type) !T {
    var found: ?T = null;

    inline for (@typeInfo(T).@"union".fields) |field| {
        const maybe_value = try table.get(ctx, field.name, ?field.type);
        if (maybe_value) |v| {
            if (found != null) return ctx.failTyped(T, "ambiguous union variant");
            found = @unionInit(T, field.name, v);
        }
    }

    return found orelse ctx.failTyped(T, "no matching union variant");
}

/// Decodes a Lua array table into a typed slice.
///
/// The result is allocated from the `Context` allocator so will automatically be freed when the callback returns.
///
/// Arguments:
/// - T: The target slice type.
/// - ctx: The current call context used for allocation and error reporting.
/// - table: The borrowed Lua table handle.
///
/// Returns:
/// - `T`: The decoded slice on success.
/// - `error.Failed`: When the table cannot be decoded into the target slice type.
fn decodeSlice(comptime T: type, ctx: *Context, table: Table) !T {
    const Element = @typeInfo(T).pointer.child;
    const index = switch (table.handle) {
        inline else => |idx| idx,
    };
    const len = lua.rawLen(ctx.state.luaState, index);
    const slice = try ctx.arena().alloc(Element, @intCast(len));
    errdefer ctx.arena().free(slice);

    for (0..@intCast(len)) |i| {
        slice[i] = try table.get(ctx, @as(i64, @intCast(i + 1)), Element);
    }

    return slice;
}
