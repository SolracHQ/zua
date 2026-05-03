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
const Meta = @import("../meta/meta.zig");
const helpers = @import("../meta/helpers.zig");
const MetaTable = @import("../metatable.zig");
const Native = @import("../functions/native.zig");
const Mapper = @import("mapper.zig");

pub const Encoder = @This();

pub const Primitive = Mapper.Primitive;

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
pub fn pushValue(ctx: *Context, value: anytype) !void {
    const T = @TypeOf(value);

    if (comptime Mapper.isOptional(T)) {
        if (value) |unwrapped| {
            try pushValue(ctx, unwrapped);
        } else {
            lua.pushNil(ctx.state.luaState);
        }
        return;
    }

    if (comptime T == Primitive) {
        return pushLuaPrimitive(ctx, value);
    }

    if (comptime helpers.isNativeWrapperType(T)) {
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
        return try pushValue(ctx, Native.new(value, .{}, .{}));
    }

    // Check for custom encode hook first
    if (comptime @typeInfo(T) == .@"struct" or @typeInfo(T) == .@"union" or @typeInfo(T) == .@"enum") {
        const meta = comptime Meta.getMeta(T);
        if (try meta.EncodeHook(ctx, value)) |encoded| {
            return pushValue(ctx, encoded);
        }
    }

    if (comptime T == Table or T == Function or T == Userdata) {
        switch (value.handle) {
            .borrowed, .stack_owned => |index| lua.pushValue(ctx.state.luaState, index),
            .registry_owned => |ref| _ = lua.rawGetI(ctx.state.luaState, lua.REGISTRY_INDEX, ref),
        }
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
            lua.pushInteger(ctx.state.luaState, std.math.cast(lua.Integer, value) orelse try ctx.failWithFmtTyped(lua.Integer, "integer value {d} out of range for Lua", .{value}));
        },
        .float, .comptime_float => {
            lua.pushNumber(ctx.state.luaState, @as(lua.Number, value));
        },
        .@"enum", .@"struct", .@"union" => {
            const strategy = comptime Meta.strategyOf(T);

            // Handle .object strategy: allocate as userdata with metatable
            if (comptime strategy == .object) {
                const ptr: *T = @ptrCast(@alignCast(lua.newUserdata(ctx.state.luaState, @sizeOf(T))));
                ptr.* = value;
                MetaTable.attachMetatable(ctx.state, T);
                return;
            }

            // Handle .ptr strategy: error (cannot push by value, would lose pointer)
            if (comptime strategy == .ptr) {
                @compileError(std.fmt.comptimePrint("Cannot push {s} with .ptr strategy by value: the pointer address would be lost. Return a *{s} instead. (Custom encode hooks do not yet support pointer types; if you need this feature, please open an issue.)", .{ @typeName(T), @typeName(T) }));
            }

            // Handle .table strategy: type-specific encoding
            if (comptime @typeInfo(T) == .@"enum") {
                lua.pushInteger(ctx.state.luaState, @intFromEnum(value));
                return; // Numbers in Lua can't have metatables, in case methods are needed for the enum use .object strategy instead
            } else {
                lua.createTable(ctx.state.luaState, inferArrayCapacity(value), inferRecordCapacity(value));
                const nested = Table.fromStack(ctx.state, -1);
                try fillTable(ctx, nested, value);
            }

            MetaTable.attachMetatable(ctx.state, T);
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

                if (@typeInfo(Pointee) == .@"struct" or @typeInfo(Pointee) == .@"union" or @typeInfo(Pointee) == .@"enum") {
                    const strategy = comptime Meta.strategyOf(Pointee);

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
                if (comptime Mapper.isStringValueType(T)) {
                    @compileError("This path must be unreachable since we already push string-like types as Lua strings above. Report a bug if you hit this error.");
                }
                const size = std.math.cast(i32, value.len) orelse try ctx.failWithFmtTyped(i32, "Slice is too large to push as Lua table: length {d} exceeds Lua's maximum table size {d}", .{ value.len, std.math.maxInt(c_int) });
                lua.createTable(ctx.state.luaState, size, 0);
                const nested = Table.fromStack(ctx.state, -1);
                try fillTable(ctx, nested, value);
                return;
            },
            else => @compileError(std.fmt.comptimePrint("Pointer size {s} for {s} is not supported for encoding. Please open an issue with your use case. (Custom encode hooks do not yet support pointer types; this requires a PtrEncodeHook design that is still pending.)", .{ @tagName(ptr_info.size), @typeName(T) })),
        },
        .array => {
            lua.createTable(ctx.state.luaState, inferArrayCapacity(value), 0);
            const nested = Table.fromStack(ctx.state, -1);
            try fillTable(ctx, nested, value);
        },
        .void => {
            lua.pushNil(ctx.state.luaState);
        },
        else => @compileError(std.fmt.comptimePrint("Type {s} is not yet supported for encoding. If you need this supported, please open an issue with your use case.", .{@typeName(T)})),
    }
}

/// Pushes a `Primitive` value onto the Lua stack using the appropriate Lua API call.
///
/// This function is used by the encoder when a Zig value is represented as a `Primitive`
/// for custom encode hooks or when the value is already a `Primitive`.
pub fn pushLuaPrimitive(ctx: *Context, value: Primitive) !void {
    switch (value) {
        .nil => lua.pushNil(ctx.state.luaState),
        .boolean => |b| lua.pushBoolean(ctx.state.luaState, b),
        .integer => |i| lua.pushInteger(ctx.state.luaState, i),
        .float => |f| lua.pushNumber(ctx.state.luaState, f),
        .string => |s| lua.pushString(ctx.state.luaState, s),
        .table => |t| try pushValue(ctx, t),
        .function => |f| try pushValue(ctx, f),
        .light_userdata => |p| lua.pushLightUserdata(ctx.state.luaState, p),
        .userdata => |u| try pushValue(ctx, u),
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
                if (comptime Mapper.isStringValueType(T)) {
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
        .@"union" => 0, // Tagged unions have no array elements
        .array => @intCast(value.len),
        .pointer => |pointer| switch (pointer.size) {
            .slice => if (comptime Mapper.isStringValueType(T))
                @compileError(std.fmt.comptimePrint("String-like slice {s} cannot be converted to a Lua table: strings are always represented as Lua strings, not tables.", .{@typeName(T)}))
            else
                std.math.cast(i32, value.len) orelse @panic("slice too large for Lua table"),
            else => @compileError(std.fmt.comptimePrint("Pointer size {s} for {s} is not supported for table conversion. Only slices are supported. Custom encode hooks do not yet support pointer types; if you need this feature, please open an issue.", .{ @tagName(pointer.size), @typeName(T) })),
        },
        else => @compileError(std.fmt.comptimePrint("Type {s} is not supported for array capacity inference. Only structs, unions, arrays, and slices are supported.", .{@typeName(T)})),
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
        .@"union" => 1, // Tagged unions always have exactly one active variant
        .array, .pointer => 0,
        else => @compileError(std.fmt.comptimePrint("Type {s} is not supported for record capacity inference. Only structs, unions, arrays, and slices are supported.", .{@typeName(T)})),
    };
}

test {
    std.testing.refAllDecls(@This());
}
