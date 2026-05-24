//! Internal decode pipeline with explicit trace management.
//!
//! Every function here takes a `Trace` parameter that records the
//! navigation path (struct field names, array indices, tuple arg
//! positions) through nested decodes. When a field or element fails,
//! the trace pinpoints exactly where in the value tree the error
//! occurred.
//!
//! Most callers should use `Mapper.Decoder.pop`, `decode`, `decodeType`,
//! or `parseTuple` instead. These transparently allocate a trace,
//! format the path on error, and set `ctx.err`. Only reach for this
//! module when you need to reuse a trace across multiple decodes or
//! handle structured errors manually.

const std = @import("std");
const lua = @import("../../../lua/lua.zig");

const Table = @import("../../handlers/any/table.zig");
const Function = @import("../../handlers/any/function.zig");
const UserdataImport = @import("../../handlers/any/userdata.zig");
const Handle = @import("../../handlers/api.zig").Handle;
const Context = @import("../../context.zig");
const ShapeData = @import("../../shape/shape_data.zig");

const ObjectType = @import("../../handlers/typed/object.zig").Object;

const Mapper = @import("../api.zig");
const Internals = @import("../internals.zig");

const Primitive = Mapper.Primitive;
const PrimitiveTag = Mapper.PrimitiveTag;
const Tracing = @import("tracing.zig");
const Trace = Tracing.Trace;
const DecodeError = Tracing.DecodeError;

/// Converts a comptime tuple of types or a single type into a Zig tuple
/// type suitable for holding decoded values.
pub fn ParseResult(comptime types: anytype) type {
    const Ty = @TypeOf(types);
    if (Ty == type) return types;
    comptime var field_types: [types.len]type = undefined;
    inline for (types, 0..) |T, i| field_types[i] = T;
    return @Tuple(&field_types);
}

/// Decodes function arguments. Sets arg-position trace segments and
/// enforces arity from the function call contract.
pub fn parseArgsDepth(
    ctx: *Context,
    start_index: lua.StackIndex,
    value_count: lua.StackCount,
    comptime types: anytype,
    trace: Trace,
) !ParseResult(types) {
    if (@TypeOf(types) == type) {
        trace.set(.{ .arg = 0 });
        return parseSingleDepth(ctx, start_index, value_count, types, trace.child());
    }
    return parseArgsMultiDepth(ctx, start_index, value_count, types, trace);
}

fn parseArgsMultiDepth(
    ctx: *Context,
    start_index: lua.StackIndex,
    value_count: lua.StackCount,
    comptime types: anytype,
    trace: Trace,
) !ParseResult(types) {
    comptime var min_arity: usize = 0;
    inline for (types) |T| {
        if (comptime !Internals.isOptional(T)) min_arity += 1;
    }
    if (value_count < min_arity or value_count > types.len) {
        trace.err.* = .{ .tag = .invalid_arity };
        return error.Failed;
    }
    var values: ParseResult(types) = undefined;
    inline for (types, 0..) |T, i| {
        const si = start_index + @as(lua.StackIndex, @intCast(i));
        trace.set(.{ .arg = i });
        const arg_trace = trace.child();
        if (comptime Internals.isOptional(T)) {
            values[i] = if (i >= value_count) null else try decodeAtDepth(ctx, si, T, arg_trace);
        } else {
            if (i >= value_count) {
                trace.err.* = .{ .tag = .invalid_arity };
                return error.Failed;
            }
            values[i] = try decodeAtDepth(ctx, si, T, arg_trace);
        }
    }
    return values;
}

/// Decodes return values and direct decode calls. Positional, no
/// argument-level trace framing.
pub fn parseTupleDepth(
    ctx: *Context,
    start_index: lua.StackIndex,
    value_count: lua.StackCount,
    comptime types: anytype,
    trace: Trace,
) !ParseResult(types) {
    if (@TypeOf(types) == type) return parseSingleDepth(ctx, start_index, value_count, types, trace);
    return parseMultiDepth(ctx, start_index, value_count, types, trace);
}

fn parseSingleDepth(
    ctx: *Context,
    start_index: lua.StackIndex,
    value_count: lua.StackCount,
    comptime T: type,
    trace: Trace,
) !T {
    if (comptime T == Mapper.VarArgs) return buildVarArgs(ctx, start_index, @intCast(value_count));
    const is_opt = comptime Internals.isOptional(T);
    if (value_count == 0) {
        if (is_opt) return null;
        trace.err.* = .{ .tag = .invalid_arity, .expected = @typeName(T) };
        return error.Failed;
    }
    if (value_count > 1) {
        trace.err.* = .{ .tag = .invalid_arity, .expected = @typeName(T) };
        return error.Failed;
    }
    return try decodeAtDepth(ctx, start_index, T, trace);
}

fn parseMultiDepth(
    ctx: *Context,
    start_index: lua.StackIndex,
    value_count: lua.StackCount,
    comptime types: anytype,
    trace: Trace,
) !ParseResult(types) {
    comptime var min_arity: usize = 0;
    inline for (types) |T| {
        if (comptime !Internals.isOptional(T)) min_arity += 1;
    }
    if (value_count < min_arity or value_count > types.len) {
        trace.err.* = .{ .tag = .invalid_arity };
        return error.Failed;
    }
    var values: ParseResult(types) = undefined;
    inline for (types, 0..) |T, i| {
        const si = start_index + @as(lua.StackIndex, @intCast(i));
        if (comptime Internals.isOptional(T)) {
            values[i] = if (i >= value_count) null else try decodeAtDepth(ctx, si, T, trace);
        } else {
            if (i >= value_count) {
                trace.err.* = .{ .tag = .invalid_arity };
                return error.Failed;
            }
            values[i] = try decodeAtDepth(ctx, si, T, trace);
        }
    }
    return values;
}

fn decodeHostPtr(comptime T: type, prim: Primitive, ctx: *Context) !T {
    const Pointee = switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
    const strategy = comptime ShapeData.strategyOf(Pointee);
    switch (strategy) {
        .object, .closure => {
            const raw = switch (prim) {
                .userdata => |p| p,
                else => return ctx.failWithFmtTyped(T, "expected userdata but got {s}", .{@tagName(prim)}),
            };
            if (comptime strategy == .object) return ObjectType(Pointee).from(raw).get();
            return @ptrCast(@alignCast(raw));
        },
        .ptr => {
            const raw = switch (prim) {
                .light_userdata => |p| p,
                else => return ctx.failWithFmtTyped(T, "expected light userdata but got {s}", .{@tagName(prim)}),
            };
            return @ptrCast(@alignCast(raw));
        },
        else => return ctx.failTyped(T, "expected object, closure, or pointer strategy"),
    }
}

fn buildPrimitiveError(ctx: *Context, t: lua.Type) !Primitive {
    return ctx.failWithFmtTyped(Primitive, "Lua reports {s} but decoding it failed", .{@tagName(t)});
}

fn buildPrimitive(ctx: *Context, index: lua.StackIndex) !Primitive {
    const state = ctx.state;
    return switch (lua.valueType(state.luaState, index)) {
        .boolean => .{ .boolean = lua.toBoolean(state.luaState, index) },
        .number => if (lua.isInteger(state.luaState, index))
            .{ .integer = lua.toInteger(state.luaState, index) orelse return buildPrimitiveError(ctx, .number) }
        else
            .{ .float = lua.toNumber(state.luaState, index) orelse return buildPrimitiveError(ctx, .number) },
        .string => .{ .string = lua.toString(state.luaState, index) orelse return buildPrimitiveError(ctx, .string) },
        .table => .{ .table = @import("../../handlers/any/table.zig").fromBorrowed(state, index) },
        .function => .{ .function = @import("../../handlers/any/function.zig").fromBorrowed(state, index) },
        .userdata => .{ .userdata = @import("../../handlers/any/userdata.zig").Userdata.fromBorrowed(state, index) },
        .light_userdata => .{ .light_userdata = lua.toLightUserdata(state.luaState, index) orelse return buildPrimitiveError(ctx, .light_userdata) },
        .thread => .{ .handle = Handle{ .borrowed = lua.absIndex(state.luaState, index) } },
        .nil, .none => .nil,
    };
}

/// Collects remaining Lua arguments as a `VarArgs` slice. The slice is
/// allocated from the context arena and valid for the duration of the call.
pub fn buildVarArgs(ctx: *Context, start_index: lua.StackIndex, count: usize) !Mapper.VarArgs {
    const arr = try ctx.arena().alloc(Primitive, count);
    for (0..count) |i| {
        arr[i] = try buildPrimitive(ctx, start_index + @as(lua.StackIndex, @intCast(i)));
    }
    return .{ .args = arr };
}

/// Pops a value from the top of the Lua stack and returns its string
/// representation using Lua's `tostring`. The stack slot is removed.
pub fn popString(ctx: *Context) ![]const u8 {
    if (lua.valueType(ctx.state.luaState, -1) == .nil) {
        lua.pop(ctx.state.luaState, 1);
        return "nil";
    }
    const raw = lua.toDisplayString(ctx.state.luaState, -1) orelse {
        lua.pop(ctx.state.luaState, 1);
        return ctx.failTyped([]const u8, "tostring failed");
    };
    lua.pop(ctx.state.luaState, 2);
    return ctx.arena().dupe(u8, raw);
}

/// Internals entry point for callers that manage stack indexes directly.
pub fn decodeAt(ctx: *Context, index: lua.StackIndex, comptime T: type) !T {
    const depth = comptime Tracing.maxDecodeDepth(T);
    var segs: [depth]Tracing.Segment = @splat(.empty);
    var err: Tracing.DecodeError = .{ .tag = .custom };
    const trace = Tracing.Trace{ .path = &segs, .deep = 0, .err = &err };
    return decodeAtDepth(ctx, index, T, trace);
}

/// The caller is responsible for managing the stack slot.
pub fn decodeAtDepth(ctx: *Context, index: lua.StackIndex, comptime T: type, trace: Trace) !T {
    const prim = try buildPrimitive(ctx, index);
    return decodeValueDepth(ctx, prim, T, trace);
}

/// Checks for a user-defined decode hook before dispatching to the
/// built-in type path. Hooks always take priority.
pub fn decodeValueDepth(ctx: *Context, prim: Primitive, comptime T: type, trace: Trace) !T {
    if (comptime Internals.isOptional(T)) {
        if (prim == .nil) return null;
        return try decodeValueDepth(ctx, prim, Internals.optionalChild(T), trace);
    }

    if (comptime T == Primitive) return prim;

    if (comptime T == void) {
        if (prim != .nil) {
            trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
            return error.Failed;
        }
        return;
    }

    if (prim == .nil) {
        trace.err.* = .{ .tag = .unexpected_nil, .expected = @typeName(T) };
        return error.Failed;
    }

    if (comptime T == Table or T == Function or T == UserdataImport.Userdata) {
        if (comptime T == Table) return switch (prim) {
            .table => |t| t,
            else => {
                trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
                return error.Failed;
            },
        };
        if (comptime T == Function) return switch (prim) {
            .function => |f| f,
            else => {
                trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
                return error.Failed;
            },
        };
        return switch (prim) {
            .userdata => |u| u,
            else => {
                trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
                return error.Failed;
            },
        };
    }

    if (comptime ShapeData.getShape(T).DecodeHook) |hook| {
        if (try hook(ctx, prim)) |decoded| return decoded;
    }

    return switch (comptime @typeInfo(T)) {
        .pointer => |ptr_info| decodePointer(T, ptr_info, prim, ctx, trace),
        .@"struct" => decodeStructValue(T, prim, ctx, trace),
        .@"union" => decodeUnionValue(T, prim, ctx, trace),
        .@"enum" => decodeEnum(T, prim, trace),
        .bool => switch (prim) {
            .boolean => |b| b,
            else => {
                trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
                return error.Failed;
            },
        },
        .int => switch (prim) {
            .integer => |i| std.math.cast(T, i) orelse {
                trace.err.* = .{ .tag = .out_of_range, .expected = @typeName(T) };
                return error.Failed;
            },
            .string => |s| if (s.len == 1) @intCast(s[0]) else {
                trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = .string };
                return error.Failed;
            },
            else => {
                trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
                return error.Failed;
            },
        },
        .float => switch (prim) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => {
                trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
                return error.Failed;
            },
        },
        .array => |arrayType| switch (prim) {
            .table => |arrayLikeTable| {
                const expected_size = arrayType.len;
                const slice = try decodeSliceDepth([]arrayType.child, ctx, arrayLikeTable, trace);
                if (slice.len != expected_size) {
                    trace.err.* = .{ .tag = .out_of_range, .expected = @typeName(T) };
                    return error.Failed;
                }
                return slice[0..expected_size].*;
            },
            else => {
                trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
                return error.Failed;
            },
        },
        else => if (comptime Internals.isStringValueType(T))
            switch (prim) {
                .string => |s| s,
                else => {
                    trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
                    return error.Failed;
                },
            }
        else
            @compileError(@typeName(T) ++ " is not decodable yet"),
    };
}

fn decodePointer(
    comptime T: type,
    comptime ptr_info: std.builtin.Type.Pointer,
    prim: Primitive,
    ctx: *Context,
    trace: Trace,
) !T {
    if (ptr_info.size == .one) {
        const Pointee = ptr_info.child;
        if (comptime @typeInfo(Pointee) == .@"struct" or @typeInfo(Pointee) == .@"union" or @typeInfo(Pointee) == .@"opaque") {
            return decodeHostPtr(T, prim, ctx);
        }
    }

    if (comptime ptr_info.size == .slice and !Internals.isStringValueType(T)) {
        const tbl = switch (prim) {
            .table => |t| t,
            else => {
                trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
                return error.Failed;
            },
        };
        return decodeSliceDepth(T, ctx, tbl, trace);
    }

    if (comptime Internals.isStringValueType(T)) {
        return switch (prim) {
            .string => |s| s,
            .table => |t| {
                const children = try decodeSliceDepth([]const u8, ctx, t, trace);
                return if (comptime T == [:0]const u8) try ctx.arena().dupeZ(u8, children) else children;
            },
            else => {
                trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
                return error.Failed;
            },
        };
    }

    @compileError("unsupported pointer type " ++ @typeName(T));
}

fn decodeStructValue(comptime T: type, prim: Primitive, ctx: *Context, trace: Trace) !T {
    const strategy = comptime ShapeData.strategyOf(T);

    if (comptime strategy == .object or strategy == .ptr) {
        return (try decodeHostPtr(*T, prim, ctx)).*;
    }

    if (comptime strategy == .function) {
        @compileError(@typeName(T) ++ " uses .function strategy and cannot be decoded from Lua");
    }

    if (comptime T == Table) return switch (prim) {
        .table => |t| t,
        else => {
            trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
            return error.Failed;
        },
    };

    if (comptime T == Function) return switch (prim) {
        .function => |f| f,
        else => {
            trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
            return error.Failed;
        },
    };

    const tbl = switch (prim) {
        .table => |t| t,
        else => {
            trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
            return error.Failed;
        },
    };
    return decodeStructDepth(ctx, tbl, T, trace);
}

fn decodeUnionValue(comptime T: type, prim: Primitive, ctx: *Context, trace: Trace) !T {
    const strategy = comptime ShapeData.strategyOf(T);

    if (comptime strategy == .object or strategy == .ptr) {
        return (try decodeHostPtr(*T, prim, ctx)).*;
    }

    const tbl = switch (prim) {
        .table => |t| t,
        else => {
            trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
            return error.Failed;
        },
    };
    return decodeUnionDepth(ctx, tbl, T, trace);
}

fn decodeEnum(comptime T: type, prim: Primitive, trace: Trace) !T {
    const value = switch (prim) {
        .integer => |v| v,
        else => {
            trace.err.* = .{ .tag = .wrong_type, .expected = @typeName(T), .got = prim.tag() };
            return error.Failed;
        },
    };
    const tag = std.math.cast(std.meta.Tag(T), value) orelse {
        trace.err.* = .{ .tag = .out_of_range, .expected = @typeName(T) };
        return error.Failed;
    };
    return @enumFromInt(tag);
}

pub fn decodeStructDepth(ctx: *Context, table: Table, comptime T: type, trace: Trace) !T {
    var result: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        trace.set(.{ .field = field.name });
        if (comptime field.default_value_ptr) |default| {
            if (try Table.Internals.getDepth(table, ctx, field.name, ?field.type, trace.child())) |val| {
                @field(result, field.name) = val;
            } else {
                @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(default))).*;
            }
        } else {
            @field(result, field.name) = try Table.Internals.getDepth(table, ctx, field.name, field.type, trace.child());
        }
    }
    return result;
}

pub fn decodeUnionDepth(ctx: *Context, table: Table, comptime T: type, trace: Trace) !T {
    var found: ?T = null;
    inline for (@typeInfo(T).@"union".fields) |field| {
        trace.set(.{ .field = field.name });
        const maybe_value = try Table.Internals.getDepth(table, ctx, field.name, ?field.type, trace.child());
        if (maybe_value) |v| {
            if (found != null) {
                trace.err.* = .{ .tag = .ambiguous_variant, .detail = @typeName(T) };
                return error.Failed;
            }
            found = @unionInit(T, field.name, v);
        }
    }
    if (found) |f| return f;
    trace.err.* = .{ .tag = .missing_field, .detail = @typeName(T) };
    return error.Failed;
}

fn decodeSliceDepth(comptime T: type, ctx: *Context, table: Table, trace: Trace) !T {
    const Element = @typeInfo(T).pointer.child;
    const index = table.pushForAccess();
    defer lua.pop(ctx.state.luaState, 1);
    const len = lua.rawLen(ctx.state.luaState, index);
    const slice = try ctx.arena().alloc(Element, @intCast(len));
    errdefer ctx.arena().free(slice);

    for (0..@intCast(len)) |i| {
        trace.set(.{ .index = i });
        slice[i] = try Table.Internals.getDepth(table, ctx, @as(i64, @intCast(i + 1)), Element, trace.child());
    }

    return slice;
}
