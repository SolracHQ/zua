//! Internal encode helpers for primitive and table-level operations.
//!
//! Most callers should use `Mapper.Encoder.push` instead. These functions
//! are exposed under `Mapper.Encoder.Internals` for manual control over
//! table construction when the type dispatch in `push` is not appropriate.

const std = @import("std");
const lua = @import("../../../lua/lua.zig");

const Table = @import("../../handlers/any/table.zig");
const Function = @import("../../handlers/any/function.zig");
const Userdata = @import("../../handlers/any/userdata.zig").Userdata;
const Context = @import("../../context.zig");
const Handle = @import("../../handlers/api.zig").Handle;

const Mapper = @import("../api.zig");
const MapperInternals = @import("../internals.zig");

const Primitive = Mapper.Primitive;

/// Pushes a handle (borrowed, stack_owned, or registry_owned) onto the Lua
/// stack.
pub fn pushHandle(ctx: *Context, handle: Handle) void {
    switch (handle) {
        .borrowed, .stack_owned => |index| lua.pushValue(ctx.state.luaState, index),
        .registry_owned => |ref| _ = lua.rawGetI(ctx.state.luaState, lua.REGISTRY_INDEX, ref),
    }
}

/// Pushes a `Primitive` value onto the Lua stack using the appropriate Lua
/// API call.
pub fn pushLuaPrimitive(ctx: *Context, value: Primitive) !void {
    switch (value) {
        .nil => lua.pushNil(ctx.state.luaState),
        .boolean => |b| lua.pushBoolean(ctx.state.luaState, b),
        .integer => |i| lua.pushInteger(ctx.state.luaState, i),
        .float => |f| lua.pushNumber(ctx.state.luaState, f),
        .string => |s| lua.pushString(ctx.state.luaState, s),
        .table => |t| pushHandle(ctx, t.handle),
        .function => |f| pushHandle(ctx, f.handle),
        .light_userdata => |p| lua.pushLightUserdata(ctx.state.luaState, p),
        .userdata => |u| pushHandle(ctx, u.handle),
        .handle => |h| pushHandle(ctx, h),
    }
}

/// Recursively fills a Lua table from a Zig struct, array, tuple, or slice.
pub fn fillTable(ctx: *Context, table: Table, value: anytype) !void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.is_tuple) {
                inline for (value, 0..) |item, index| {
                    try table.set(ctx, index + 1, item);
                }
                return;
            }

            inline for (info.fields) |field| {
                try table.set(ctx, field.name, @field(value, field.name));
            }
        },
        .array => {
            for (value, 0..) |item, index| {
                try table.set(ctx, index + 1, item);
            }
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (comptime MapperInternals.isStringValueType(T)) {
                    @compileError(std.fmt.comptimePrint("String-like value {s} cannot be filled into a Lua table: string values are always pushed as Lua strings, not tables.", .{@typeName(T)}));
                }

                for (value, 0..) |item, index| {
                    try table.set(ctx, index + 1, item);
                }
            },
            else => @compileError(std.fmt.comptimePrint("Pointer size {s} for {s} is not supported for filling Lua tables. Only slices are supported.", .{ @tagName(pointer.size), @typeName(T) })),
        },
        .@"union" => {
            switch (value) {
                inline else => |v, tag| {
                    try table.set(ctx, @tagName(tag), v);
                },
            }
        },
        else => @compileError(std.fmt.comptimePrint("Type {s} is not supported for filling Lua tables. Only structs, tuples, arrays, slices, and tagged unions are supported.", .{@typeName(T)})),
    }
}

/// Infers the array portion capacity for a Lua table representation of
/// `value`.
pub fn inferArrayCapacity(value: anytype) i32 {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .@"struct" => |info| if (info.is_tuple) @intCast(info.fields.len) else 0,
        .@"union" => 0,
        .array => @intCast(value.len),
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (comptime MapperInternals.isStringValueType(T))
                @compileError(std.fmt.comptimePrint("String-like slice {s} cannot be converted to a Lua table: strings are always represented as Lua strings, not tables.", .{@typeName(T)}))
            else
                std.math.cast(i32, value.len) orelse @panic("slice too large for Lua table"),
            else => @compileError(std.fmt.comptimePrint("Pointer size {s} for {s} is not supported for table conversion. Only slices are supported. Custom encode hooks do not yet support pointer types; if you need this feature, please open an issue.", .{ @tagName(pointer.size), @typeName(T) })),
        },
        else => @compileError(std.fmt.comptimePrint("Type {s} is not supported for array capacity inference. Only structs, unions, arrays, and slices are supported.", .{@typeName(T)})),
    };
}

/// Infers the record portion capacity for a Lua table representation of
/// `value`.
pub fn inferRecordCapacity(value: anytype) i32 {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .@"struct" => |info| if (info.is_tuple) 0 else @intCast(info.fields.len),
        .@"union" => 1,
        .array, .pointer => 0,
        else => @compileError(std.fmt.comptimePrint("Type {s} is not supported for record capacity inference. Only structs, unions, arrays, and slices are supported.", .{@typeName(T)})),
    };
}
