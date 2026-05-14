//! Entry points for converting Lua values into typed Zig values.
//!
//! `pop` reads a value from the Lua stack and removes the slot.
//! `decode` converts a decoded Lua primitive into a Zig type.
//! `decodeType` converts a Lua table handle into a Zig struct or union.
//! `parseTuple` decodes a sequence of Lua stack values into a typed tuple.

const Context = @import("../../state/context.zig");
const lua = @import("../../../lua/lua.zig");

const Table = @import("../../handlers/any/table.zig");
const Primitive = @import("../mapper.zig").Primitive;
const tracing = @import("tracing.zig");

pub const Tracing = tracing;
pub const Internals = @import("decoder.zig");
pub const ParseResult = Internals.ParseResult;

pub fn DecodeResult(comptime T: type) type {
    const depth = tracing.maxDecodeDepth(T);
    return union(enum) {
        ok: T,
        err: struct { path: [depth]tracing.Segment, err: tracing.DecodeError },
    };
}

fn makeTrace(comptime types: anytype) struct { path: [tracing.maxDecodeDepth(types)]tracing.Segment, err: tracing.DecodeError } {
    return .{
        .path = @splat(.empty),
        .err = .{ .tag = .custom },
    };
}

fn formatTrace(arena: *Context, path: []const tracing.Segment, err: tracing.DecodeError) []const u8 {
    const p = tracing.formatDecodePath(arena.arena(), path) catch "";
    const m = err.format(arena.arena()) catch "decode failed";
    return if (p.len > 0)
        std.fmt.allocPrint(arena.arena(), "{s}: {s}", .{ p, m }) catch m
    else
        m;
}

/// Parses a sequence of Lua stack values into a typed Zig tuple.
///
/// Supports optional trailing arguments. Used by `Executor.eval` and
/// `Function.call` to decode return values.
pub fn parseTuple(
    ctx: *Context,
    start_index: lua.StackIndex,
    value_count: lua.StackCount,
    comptime types: anytype,
) !ParseResult(types) {
    var arena = makeTrace(types);
    const trace = tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    return Internals.parseTupleDepth(ctx, start_index, value_count, types, trace) catch {
        if (ctx.err == null) ctx.err = formatTrace(ctx, &arena.path, arena.err);
        return error.Failed;
    };
}

/// Reads a value from the top of the Lua stack as type `T` and pops it.
///
/// The value is decoded and the stack slot is removed. Handle types
/// (`Table`, `Function`, `Userdata`) are returned as borrowed handles
/// that become invalid after the pop — use `.owned()` first if needed.
pub fn pop(ctx: *Context, comptime T: type) !T {
    var arena = makeTrace(T);
    const trace = tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    const val = Internals.decodeAtDepth(ctx, -1, T, trace) catch {
        if (ctx.err == null) ctx.err = formatTrace(ctx, &arena.path, arena.err);
        return error.Failed;
    };
    lua.pop(ctx.state.luaState, 1);
    return val;
}

/// Decodes a Primitive into a Zig type `T`.
///
/// This is the core decode operation — given a Primitive, decode it as T.
/// Does not touch the Lua stack. Use `pop` to read and remove a value from
/// the stack, use `decodeType` when you have a Lua table handle.
pub fn decode(ctx: *Context, prim: Primitive, comptime T: type) !T {
    var arena = makeTrace(T);
    const trace = tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    return Internals.decodeValueDepth(ctx, prim, T, trace) catch {
        if (ctx.err == null) ctx.err = formatTrace(ctx, &arena.path, arena.err);
        return error.Failed;
    };
}

/// Decodes a Lua table into a Zig struct/union/enum by field mapping.
///
/// Reads each field from the table using the type's `ZUA_SHAPE` strategy.
/// Struct fields use their field names as keys. Unions match the active variant.
/// Fields with defaults preserve Lua's missing-key semantics.
pub fn decodeType(ctx: *Context, table: Table, comptime T: type) !T {
    var arena = makeTrace(T);
    const trace = tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    return Internals.decodeStructDepth(ctx, table, T, trace) catch {
        if (ctx.err == null) ctx.err = formatTrace(ctx, &arena.path, arena.err);
        return error.Failed;
    };
}

/// Decodes a Primitive as `T`, returning a tagged union with the value
/// or structured error information including the decode trace.
pub fn decodeResult(ctx: *Context, prim: Primitive, comptime T: type) DecodeResult(T) {
    var arena = makeTrace(T);
    const trace = tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    return Internals.decodeValueDepth(ctx, prim, T, trace) catch return .{
        .err = .{ .path = arena.path, .err = arena.err },
    };
}

/// Decodes a Lua table as `T`, returning a tagged union with the value
/// or structured error information including the decode trace.
pub fn decodeTypeResult(ctx: *Context, table: Table, comptime T: type) DecodeResult(T) {
    var arena = makeTrace(T);
    const trace = tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    return Internals.decodeStructDepth(ctx, table, T, trace) catch return .{
        .err = .{ .path = arena.path, .err = arena.err },
    };
}

/// Pops a value from the stack as `T`, returning a tagged union with
/// the value or structured error information including the decode trace.
/// The Lua stack slot is always removed, even on failure.
pub fn popResult(ctx: *Context, comptime T: type) DecodeResult(T) {
    var arena = makeTrace(T);
    const trace = tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    const result = Internals.decodeAtDepth(ctx, -1, T, trace);
    lua.pop(ctx.state.luaState, 1);
    return if (result) |val| .{ .ok = val } else .{ .err = .{ .path = arena.path, .err = arena.err } };
}

const std = @import("std");
