//! Converts Lua values into typed Zig values.
//!
//! Call `pop` to read and consume a value from the top of the Lua stack,
//! `decode` to convert a `Primitive` you already hold, or `decodeType` to
//! map a Lua table's fields onto a Zig struct or union by name. Use
//! `parseTuple` when a Lua call returns multiple values.
//!
//! Every decode function reports structured errors with path traces
//! that point to the exact field or index that failed.
//!
//! `pop` and `popResult` own any handler types in the returned value
//! before removing the Lua stack slot. Other functions (`decode`,
//! `decodeType`, `parseTuple`) return borrowed handles that stay valid
//! only during the caller's stack frame. Call `.owned()` first if you
//! need to keep them.

const lua = @import("../../../lua/lua.zig");
const Context = @import("../../context.zig");
const Table = @import("../../handlers/any/table.zig");
const Primitive = @import("../api.zig").Primitive;
const Handlers = @import("../../handlers/api.zig");

pub const Tracing = @import("tracing.zig");
pub const Internals = @import("internals.zig");
pub const ParseResult = Internals.ParseResult;

/// Tagged union that carries either a decoded value or a structured error
/// trace pointing to the exact field or index that failed.
pub fn DecodeResult(comptime T: type) type {
    const depth = Tracing.maxDecodeDepth(T);
    return union(enum) {
        ok: T,
        err: struct { path: [depth]Tracing.Segment, err: Tracing.DecodeError },
    };
}

fn makeTrace(comptime types: anytype) struct { path: [Tracing.maxDecodeDepth(types)]Tracing.Segment, err: Tracing.DecodeError } {
    return .{
        .path = @splat(.empty),
        .err = .{ .tag = .custom },
    };
}

fn formatTrace(arena: *Context, path: []const Tracing.Segment, err: Tracing.DecodeError) []const u8 {
    const p = Tracing.formatDecodePath(arena.arena(), path) catch "";
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
    const trace = Tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    return Internals.parseTupleDepth(ctx, start_index, value_count, types, trace) catch {
        if (ctx.err == null) ctx.err = formatTrace(ctx, &arena.path, arena.err);
        return error.Failed;
    };
}

/// Reads a value from the top of the Lua stack as type `T` and pops it.
///
/// Any handler types (`Table`, `Function`, `Userdata`) embedded in the
/// returned value are converted to owned (registry) handles before the
/// stack slot is removed. Call `.release()` on them when you are done.
pub fn pop(ctx: *Context, comptime T: type) !T {
    var arena = makeTrace(T);
    const trace = Tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    var val = Internals.decodeAtDepth(ctx, -1, T, trace) catch {
        if (ctx.err == null) ctx.err = formatTrace(ctx, &arena.path, arena.err);
        return error.Failed;
    };
    Handlers.takeOwnership(&val);
    lua.pop(ctx.state.luaState, 1);
    return val;
}

/// Decodes a Primitive into a Zig type `T`.
///
/// This is the core decode operation. Given a Primitive, decode it as T.
/// Does not touch the Lua stack. Use `pop` to read and remove a value from
/// the stack, use `decodeType` when you have a Lua table handle.
pub fn decode(ctx: *Context, prim: Primitive, comptime T: type) !T {
    var arena = makeTrace(T);
    const trace = Tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
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
    const trace = Tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    return Internals.decodeStructDepth(ctx, table, T, trace) catch {
        if (ctx.err == null) ctx.err = formatTrace(ctx, &arena.path, arena.err);
        return error.Failed;
    };
}

/// Decodes a Primitive as `T`, returning a tagged union with the value
/// or structured error information including the decode trace.
pub fn decodeResult(ctx: *Context, prim: Primitive, comptime T: type) DecodeResult(T) {
    var arena = makeTrace(T);
    const trace = Tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    return Internals.decodeValueDepth(ctx, prim, T, trace) catch return .{
        .err = .{ .path = arena.path, .err = arena.err },
    };
}

/// Decodes a Lua table as `T`, returning a tagged union with the value
/// or structured error information including the decode trace.
pub fn decodeTypeResult(ctx: *Context, table: Table, comptime T: type) DecodeResult(T) {
    var arena = makeTrace(T);
    const trace = Tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    return Internals.decodeStructDepth(ctx, table, T, trace) catch return .{
        .err = .{ .path = arena.path, .err = arena.err },
    };
}

/// Pops a value from the stack as `T`, returning a tagged union with
/// the value or structured error information including the decode trace.
/// The Lua stack slot is always removed, even on failure.
///
/// On success any handler types embedded in the value are converted to
/// owned handles. Call `.release()` on them when you are done.
pub fn popResult(ctx: *Context, comptime T: type) DecodeResult(T) {
    var arena = makeTrace(T);
    const trace = Tracing.Trace{ .path = &arena.path, .deep = 0, .err = &arena.err };
    const result = Internals.decodeAtDepth(ctx, -1, T, trace);
    lua.pop(ctx.state.luaState, 1);
    return if (result) |val| {
        var owned = val;
        Handlers.takeOwnership(&owned);
        .{ .ok = owned };
    } else .{ .err = .{ .path = arena.path, .err = arena.err } };
}

const std = @import("std");

