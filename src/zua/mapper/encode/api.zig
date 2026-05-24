//! How a Zig type maps to its Lua representation.
//!
//! Call `push` to convert a Zig value to a Lua value on the stack.
//! Internal helpers for manual table construction are available under
//! `Internals`.

const std = @import("std");
const lua = @import("../../../lua/lua.zig");

const Table = @import("../../handlers/any/table.zig");
const Function = @import("../../handlers/any/function.zig");
const Userdata = @import("../../handlers/any/userdata.zig").Userdata;
const UpValue = @import("../../handlers/any/upvalue.zig");
const Context = @import("../../context.zig");
const State = @import("../../state.zig");

pub const Internals = @import("internals.zig");

const Mapper = @import("../api.zig");
const Shape = @import("../../shape/api.zig");
const ShapeData = @import("../../shape/shape_data.zig");
const MetaTable = @import("../../metatable.zig");
const MapperInternals = @import("../internals.zig");

const Primitive = Mapper.Primitive;

/// Pushes a Zig value onto the Lua stack.
///
/// The value is converted according to its compile-time type, including custom
/// encode hooks, value strategy metadata, and typed function wrapper support.
///
/// Arguments:
/// - ctx: The current call context used for temporary allocations and Lua state access.
/// - value: The Zig value to push.
///
/// Returns:
/// - void: The pushed value is left on the Lua stack.
///
/// Example:
/// ```zig
/// Mapper.Encoder.push(ctx, 123);
/// Mapper.Encoder.push(ctx, "hello");
/// ```
pub fn push(ctx: *Context, value: anytype) !void {
    const T = @TypeOf(value);

    if (comptime MapperInternals.isOptional(T)) {
        if (value) |unwrapped| {
            try push(ctx, unwrapped);
        } else {
            lua.pushNil(ctx.state.luaState);
        }
        return;
    }

    if (comptime T == Primitive) {
        return Internals.pushLuaPrimitive(ctx, value);
    }

    const actual_type: type = if (T == type) value else T;
    if (comptime ShapeData.trampolineOf(actual_type)) |tramp| {
        lua.pushCFunction(ctx.state.luaState, tramp);
        return;
    }

    if (comptime @typeInfo(T) == .@"fn") {
        return try push(ctx, Shape.Fn(value, .{}));
    }

    const shape = comptime ShapeData.getShape(T);
    if (shape.EncodeHook) |hook| {
        if (try hook(ctx, value)) |encoded| {
            return push(ctx, encoded);
        }
    }

    if (comptime T == Table or T == Function or T == Userdata) {
        Internals.pushHandle(ctx, value.handle);
        return;
    }

    if (comptime T == UpValue) {
        Internals.pushHandle(ctx, value.handle);
        lua.pushCClosure(ctx.state.luaState, value.cfunction, 1);
        return;
    }

    if (comptime MapperInternals.isStringValueType(T)) {
        lua.pushString(ctx.state.luaState, value);
        return;
    }

    switch (comptime @typeInfo(T)) {
        .bool => {
            lua.pushBoolean(ctx.state.luaState, value);
        },
        .int, .comptime_int => {
            lua.pushInteger(ctx.state.luaState, std.math.cast(lua.Integer, value) orelse try ctx.failWithFmtTyped(lua.Integer, "integer value {d} out of range for Lua", .{value}));
        },
        .float, .comptime_float => {
            lua.pushNumber(ctx.state.luaState, @as(lua.Number, value));
        },
        .@"enum", .@"struct", .@"union" => {
            const strategy = comptime ShapeData.strategyOf(T);

            if (comptime strategy == .object) {
                const ptr: *T = @ptrCast(@alignCast(lua.newUserdata(ctx.state.luaState, @sizeOf(T))));
                ptr.* = value;
                MetaTable.attachMetatable(ctx.state, T);
                return;
            }

            if (comptime strategy == .closure) {
                const ptr: *T = @ptrCast(@alignCast(lua.newUserdata(ctx.state.luaState, @sizeOf(T))));
                ptr.* = value;
                MetaTable.attachMetatable(ctx.state, T);
                lua.pushCClosure(ctx.state.luaState, shape.trampoline(), 1);
                return;
            }

            if (comptime strategy == .function) {
                lua.pushCFunction(ctx.state.luaState, T.ZUA_SHAPE.trampoline());
                return;
            }

            if (comptime strategy == .ptr) {
                @compileError(std.fmt.comptimePrint("Cannot push {s} with .ptr strategy by value: the pointer address would be lost. Return a *{s} instead. (Custom encode hooks do not yet support pointer types; if you need this feature, please open an issue.)", .{ @typeName(T), @typeName(T) }));
            }

            if (comptime strategy == .alias) {
                lua.pushInteger(ctx.state.luaState, @intFromEnum(value));
                return;
            }

            lua.createTable(ctx.state.luaState, Internals.inferArrayCapacity(value), Internals.inferRecordCapacity(value));
            const nested = Table.fromStack(ctx.state, -1);
            try Internals.fillTable(ctx, nested, value);

            MetaTable.attachMetatable(ctx.state, T);
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => {
                const Pointee = ptr_info.child;

                if (@typeInfo(Pointee) == .array) {
                    const arr_info = @typeInfo(Pointee).array;
                    const slice: []const arr_info.child = value[0..arr_info.len];
                    push(ctx, slice);
                    return;
                }

                if (@typeInfo(Pointee) == .@"struct" or @typeInfo(Pointee) == .@"union" or @typeInfo(Pointee) == .@"enum" or @typeInfo(Pointee) == .@"opaque") {
                    const strategy = comptime ShapeData.strategyOf(Pointee);

                    if (strategy == .object) {
                        @compileError(std.fmt.comptimePrint("Cannot push *{s} where {s} uses .object strategy: the metatable and identity would be lost. Return {s} by value instead to preserve metatable behavior and enable proper method dispatch.", .{ @typeName(Pointee), @typeName(Pointee), @typeName(Pointee) }));
                    }

                    if (strategy == .ptr) {
                        lua.pushLightUserdata(ctx.state.luaState, value);
                        return;
                    }

                    @compileError(std.fmt.comptimePrint("Pointer to {s} (strategy .{s}) cannot be pushed: only .ptr strategy types can be pushed as light userdata pointers. For .object types, push by value instead to preserve metatable behavior. For .table types, there is no workaround; please open an issue with your use case.", .{ @typeName(Pointee), @tagName(strategy) }));
                }

                @compileError(std.fmt.comptimePrint("Pointer to {s} is not yet supported for encoding. Please open an issue with your use case. (Custom encode hooks do not yet support pointer types; this requires a PtrEncodeHook design that is still pending.)", .{@typeName(Pointee)}));
            },
            .slice => {
                if (comptime MapperInternals.isStringValueType(T)) {
                    @compileError("This path must be unreachable since we already push string-like types as Lua strings above. Report a bug if you hit this error.");
                }
                const size = std.math.cast(i32, value.len) orelse try ctx.failWithFmtTyped(i32, "Slice is too large to push as Lua table: length {d} exceeds Lua's maximum table size {d}", .{ value.len, std.math.maxInt(c_int) });
                lua.createTable(ctx.state.luaState, size, 0);
                const nested = Table.fromStack(ctx.state, -1);
                try Internals.fillTable(ctx, nested, value);
                return;
            },
            else => @compileError(std.fmt.comptimePrint("Pointer size {s} for {s} is not supported for encoding. Please open an issue with your use case. (Custom encode hooks do not yet support pointer types; this requires a PtrEncodeHook design that is still pending.)", .{ @tagName(ptr_info.size), @typeName(T) })),
        },
        .array => {
            lua.createTable(ctx.state.luaState, Internals.inferArrayCapacity(value), 0);
            const nested = Table.fromStack(ctx.state, -1);
            try Internals.fillTable(ctx, nested, value);
        },
        .void => {
            lua.pushNil(ctx.state.luaState);
        },
        else => @compileError(std.fmt.comptimePrint("Type {s} is not yet supported for encoding. If you need this supported, please open an issue with your use case.", .{@typeName(T)})),
    }
}

test {
    std.testing.refAllDecls(@This());
}
