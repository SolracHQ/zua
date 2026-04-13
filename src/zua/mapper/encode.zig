//! Encoding utilities for translating Zig values into Lua values.
//!
//! This module provides the core `Encoder` interface used by the Zua metadata
//! pipeline. It handles primitive values, strings, tables, objects, functions,
//! and typed callback wrappers while preserving Lua stack and registry
//! lifetime semantics.

const std = @import("std");
const lua = @import("../../lua/lua.zig");

const Table = @import("../handlers/table.zig");
const Function = @import("../handlers/function.zig");
const Userdata = @import("../handlers/userdata.zig").Userdata;
const Context = @import("../state/context.zig");
const State = @import("../state/state.zig");
const Meta = @import("../meta.zig");
const MetaTable = @import("../metatable.zig");
const ZuaFn = @import("../functions/zua_fn.zig");
const Mapper = @import("mapper.zig");

pub const Encoder = @This();

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
/// Mapper.Encoder.pushValue(ctx, 123);
/// Mapper.Encoder.pushValue(ctx, "hello");
/// ```
pub fn pushValue(ctx: *Context, value: anytype) void {
    const T = @TypeOf(value);

    if (comptime Mapper.isOptional(T)) {
        if (value) |unwrapped| {
            pushValue(ctx, unwrapped);
        } else {
            lua.pushNil(ctx.state.luaState);
        }
        return;
    }

    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "__IsZuaFn")) {
        if (comptime T.__IsZuaClosure) {
            // Closure: push initial capture as userdata (upvalue 1), then pushcclosure.
            const CaptureType = @TypeOf(value.initial);
            const ptr: *CaptureType = @ptrCast(@alignCast(lua.newUserdata(ctx.state.luaState, @sizeOf(CaptureType))));
            ptr.* = value.initial;
            MetaTable.attachMetatable(ctx.state, CaptureType);
            lua.pushCClosure(ctx.state.luaState, T.trampoline(), 1);
        } else {
            lua.pushCFunction(ctx.state.luaState, T.trampoline());
        }
        return;
    }

    if (comptime @typeInfo(T) == .@"fn") {
        pushValue(ctx, ZuaFn.new(value, .{}));
        return;
    }

    // Check for custom encode hook first
    if (comptime @typeInfo(T) == .@"struct" or @typeInfo(T) == .@"union" or @typeInfo(T) == .@"enum") {
        const meta = comptime Meta.getMeta(T);
        if (comptime meta.encode_hook) |encode_hook| {
            const encoded = encode_hook(ctx, value);
            pushValue(ctx, encoded);
            return;
        }
    }

    if (comptime T == Table or T == Function or T == Userdata) {
        const index = switch (value.handle) {
            inline else => |idx| idx,
        };
        lua.pushValue(ctx.state.luaState, index);
        return;
    }

    if (comptime Mapper.isStringValueType(T)) {
        lua.pushString(ctx.state.luaState, value);
        return;
    }

    switch (comptime @typeInfo(T)) {
        .bool => {
            lua.pushBoolean(ctx.state.luaState, value);
        },
        .int, .comptime_int => {
            lua.pushInteger(ctx.state.luaState, std.math.cast(lua.Integer, value) orelse @panic("integer value out of range for Lua"));
        },
        .float, .comptime_float => {
            lua.pushNumber(ctx.state.luaState, @as(lua.Number, value));
        },
        .@"enum" => {
            lua.pushInteger(ctx.state.luaState, @intFromEnum(value));
        },
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => {
                const Pointee = ptr_info.child;

                // Handle *const [N]T arrays by treating as slices
                if (@typeInfo(Pointee) == .array) {
                    const arr_info = @typeInfo(Pointee).array;
                    const slice: []const arr_info.child = value[0..arr_info.len];
                    pushValue(ctx, slice);
                    return;
                }

                if (@typeInfo(Pointee) == .@"struct" or @typeInfo(Pointee) == .@"union") {
                    const strategy = comptime Meta.getMeta(Pointee).strategy;

                    if (strategy == .object) {
                        @compileError("cannot push *T where T is .object: the metatable would be lost. Return T by value instead");
                    }

                    if (strategy == .ptr) {
                        lua.pushLightUserdata(ctx.state.luaState, value);
                        return;
                    }

                    @compileError("cannot push pointer to .table type");
                }

                @compileError("unsupported push type: " ++ @typeName(T));
            },
            .slice => {
                if (comptime Mapper.isStringValueType(T)) {
                    @compileError("unsupported push type: " ++ @typeName(T));
                }

                lua.createTable(ctx.state.luaState, std.math.cast(i32, value.len) orelse @panic("slice too large"), 0);
                const nested = Table.fromStack(ctx.state, -1);
                fillTable(ctx, nested, value);
                return;
            },
            else => @compileError("unsupported push type: " ++ @typeName(T)),
        },
        .@"struct" => {
            const strategy = comptime Meta.getMeta(T).strategy;

            if (strategy == .object) {
                const ptr: *T = @ptrCast(@alignCast(lua.newUserdata(ctx.state.luaState, @sizeOf(T))));
                ptr.* = value;
                MetaTable.attachMetatable(ctx.state, T);
                return;
            }

            if (strategy == .ptr) {
                @compileError("cannot push .zig_ptr type by value: push a *T instead");
            }

            // .table strategy (including anonymous structs)
            lua.createTable(ctx.state.luaState, inferArrayCapacity(value), inferRecordCapacity(value));
            const nested = Table.fromStack(ctx.state, -1);
            fillTable(ctx, nested, value);

            MetaTable.attachMetatable(ctx.state, T);
        },
        .@"union" => {
            const strategy = comptime Meta.getMeta(T).strategy;

            if (strategy == .object) {
                const ptr: *T = @ptrCast(@alignCast(lua.newUserdata(ctx.state.luaState, @sizeOf(T))));
                ptr.* = value;
                MetaTable.attachMetatable(ctx.state, T);
                return;
            }

            if (strategy == .ptr) {
                @compileError("cannot push .zig_ptr union by value: push a *T instead");
            }

            lua.createTable(ctx.state.luaState, 0, 1);
            const table = Table.fromStack(ctx.state, -1);
            switch (value) {
                inline else => |v, tag| {
                    table.set(ctx, @tagName(tag), v);
                },
            }

            MetaTable.attachMetatable(ctx.state, T);
        },
        .array => {
            lua.createTable(ctx.state.luaState, inferArrayCapacity(value), 0);
            const nested = Table.fromStack(ctx.state, -1);
            fillTable(ctx, nested, value);
        },
        else => @compileError("unsupported push type: " ++ @typeName(T)),
    }
}

/// Recursively fills a Lua table from a Zig struct, array, tuple, or slice.
///
/// This helper is used by the encoder when a Zig value is represented as a Lua
/// table. It writes integer keys for array-like data and string keys for struct
/// fields.
///
/// Arguments:
/// - ctx: The current call context used for temporary allocations and error reporting.
/// - table: The Lua table handle to fill.
/// - value: The Zig value to encode into the Lua table.
///
/// Returns:
/// - void: The table is mutated in place.
pub fn fillTable(ctx: *Context, table: Table, value: anytype) void {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.is_tuple) {
                inline for (value, 0..) |item, index| {
                    table.set(ctx, index + 1, item);
                }
                return;
            }

            inline for (info.fields) |field| {
                table.set(ctx, field.name, @field(value, field.name));
            }
        },
        .array => {
            for (value, 0..) |item, index| {
                table.set(ctx, index + 1, item);
            }
        },
        .pointer => |pointer| switch (pointer.size) {
            .slice => {
                if (comptime Mapper.isStringValueType(T)) {
                    @compileError("string-like values must be stored as Lua strings, not table fills");
                }

                for (value, 0..) |item, index| {
                    table.set(ctx, index + 1, item);
                }
            },
            else => @compileError("unsupported table fill type: " ++ @typeName(T)),
        },
        else => @compileError("unsupported table fill type: " ++ @typeName(T)),
    }
}

/// Infers the array portion capacity for a Lua table representation of `value`.
///
/// This is used to allocate the Lua table with an appropriate initial array
/// capacity before populating it from a tuple, array, or slice.
///
/// Arguments:
/// - value: The Zig value to represent as a Lua table.
///
/// Returns:
/// - i32: The inferred array capacity.
pub fn inferArrayCapacity(value: anytype) i32 {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .@"struct" => |info| if (info.is_tuple) @intCast(info.fields.len) else 0,
        .array => @intCast(value.len),
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (comptime Mapper.isStringValueType(T))
                @compileError("string-like values are not table-convertible")
            else
                std.math.cast(i32, value.len) orelse @panic("slice too large for Lua table"),
            else => @compileError("unsupported table conversion type: " ++ @typeName(T)),
        },
        else => @compileError("unsupported table conversion type: " ++ @typeName(T)),
    };
}

/// Infers the record portion capacity for a Lua table representation of `value`.
///
/// This is used to allocate the Lua table with an appropriate initial record
/// capacity before populating it from a struct.
///
/// Arguments:
/// - value: The Zig value to represent as a Lua table.
///
/// Returns:
/// - i32: The inferred record capacity.
pub fn inferRecordCapacity(value: anytype) i32 {
    const T = @TypeOf(value);

    return switch (@typeInfo(T)) {
        .@"struct" => |info| if (info.is_tuple) 0 else @intCast(info.fields.len),
        .array, .pointer => 0,
        else => @compileError("unsupported table conversion type: " ++ @typeName(T)),
    };
}
