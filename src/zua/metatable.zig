//! Metatable creation and attachment for Zua values.
//!
//! Builds metatables from `ZUA_SHAPE` declarations, wires methods and
//! metamethods, and attaches them to userdata values.

const std = @import("std");
const lua = @import("../lua/lua.zig");
const ShapeData = @import("shape/shape_data.zig");
const Shape = @import("shape/api.zig");
const Modifier = @import("shape/modifier.zig");
const Marker = @import("marker.zig");
const State = @import("state.zig");
const Context = @import("context.zig");
const Mapper = @import("mapper/api.zig");

/// Attaches the metatable for `T` to the value on top of the Lua stack.
///
/// Call this after pushing a userdata value to give it method dispatch and
/// metamethod behavior. The metatable is created once and cached on the
/// state. Must be called with the target value at the top of the Lua stack.
pub fn attachMetatable(state: *State, comptime T: type) void {
    state.getOrCreateMetatable(T);
    _ = lua.setMetatable(state.luaState, -2);
}

/// Builds the metatable for `T` and leaves it on the Lua stack.
///
/// Object strategy types receive a `__name` field for diagnostics. Methods
/// declared in `ZUA_SHAPE` are wired into the metatable. Struct fields
/// wrapping `Shape.Modifier.Field` or `Shape.Modifier.Value` get automatic
/// Lua field access.
///
/// The metatable is pushed on top of the Lua stack. Caller must pop or use
/// it before the next stack operation.
///
/// Arguments:
/// - state: The global Zua state owning the Lua VM.
/// - T: The type whose metatable is being constructed.
pub fn buildMetatable(state: *State, comptime T: type) void {
    const strategy = ShapeData.strategyOf(T);

    lua.createTable(state.luaState, 0, 6);
    const mt_index = lua.absIndex(state.luaState, -1);

    if (strategy == .object) {
        lua.pushString(state.luaState, @typeName(T));
        lua.setField(state.luaState, mt_index, "__name");
    }

    const methods = comptime ShapeData.methodsOf(T);
    const methods_type = @TypeOf(methods);
    const has_custom_index = comptime @hasField(methods_type, "__index");
    const has_custom_newindex = comptime @hasField(methods_type, "__newindex");
    const regular_count = comptime regularMethodCount(T);
    const field_count = comptime objectFieldCount(T);
    const has_fields = field_count > 0;

    if (regular_count == 0 and !has_fields and !has_custom_index and !has_custom_newindex and strategy != .object) return;

    var methods_index: i32 = 0;
    if (regular_count > 0) {
        lua.createTable(state.luaState, 0, regular_count);
        methods_index = lua.absIndex(state.luaState, -1);
    }

    inline for (@typeInfo(methods_type).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "__index") or std.mem.eql(u8, field.name, "__newindex")) continue;

        const method_fn = @field(methods, field.name);
        lua.pushFunction(state.luaState, selectTrampoline(method_fn, field.name));

        if (comptime std.mem.startsWith(u8, field.name, "__")) {
            lua.setField(state.luaState, mt_index, field.name);
        } else {
            lua.setField(state.luaState, methods_index, field.name);
        }
    }

    const needs_index = regular_count > 0 or has_fields or has_custom_index;
    if (needs_index) {
        lua.pushFunction(state.luaState, objectIndexTrampoline(T));
        lua.setField(state.luaState, mt_index, "__index");
    }

    const needs_newindex = has_fields or has_custom_newindex;
    if (needs_newindex) {
        lua.pushFunction(state.luaState, objectNewIndexTrampoline(T));
        lua.setField(state.luaState, mt_index, "__newindex");
    }

    if (needs_index and regular_count > 0) {
        lua.pop(state.luaState, 1);
    }
}

fn selectTrampoline(comptime method_fn: anytype, comptime name: []const u8) lua.CFunction {
    const method_fn_type = @TypeOf(method_fn);

    if (comptime ShapeData.isFunction(method_fn_type)) {
        return method_fn_type.trampoline();
    }

    if (comptime @typeInfo(method_fn_type) == .type and ShapeData.isFunction(method_fn)) {
        return method_fn.trampoline();
    }

    if (comptime @typeInfo(method_fn_type) != .@"fn") {
        @compileError("method `" ++ name ++ "` is not a function");
    }

    return Shape.Fn(method_fn, .{}).trampoline();
}

fn pushFieldValue(comptime T: type, comptime field_name: []const u8, state: *lua.State, ctx: *Context) !void {
    const self_ptr: *T = @ptrCast(@alignCast(lua.toUserdata(state, 1) orelse return));
    try Mapper.Encoder.push(ctx, @field(self_ptr, field_name).value);
}

fn decodeFieldValue(comptime T: type, comptime field_name: []const u8, comptime InnerType: type, state: *lua.State, ctx: *Context) !void {
    const val = try Mapper.Decoder.pop(ctx, InnerType);
    const self_ptr: *T = @ptrCast(@alignCast(lua.toUserdata(state, 1) orelse return));
    @field(self_ptr, field_name).value = val;
}

fn fieldIndex(L: ?*lua.State, comptime T: type, comptime field_name: []const u8) c_int {
    const state = L orelse unreachable;
    const vm = State.fromState(state) orelse {
        lua.pushString(state, "failed to retrieve Zua context");
        return lua.raiseError(state);
    };
    var ctx = Context.init(vm);
    lua.pop(state, 1);
    pushFieldValue(T, field_name, state, &ctx) catch |err| {
        const msg = ctx.err orelse @errorName(err);
        lua.pushString(state, msg);
        ctx.deinit();
        return lua.raiseError(state);
    };
    ctx.deinit();
    return 1;
}

fn fieldNewIndex(L: ?*lua.State, comptime T: type, comptime field_name: []const u8, comptime InnerType: type) c_int {
    const state = L orelse unreachable;
    const vm = State.fromState(state) orelse {
        lua.pushString(state, "failed to retrieve Zua context");
        return lua.raiseError(state);
    };
    var ctx = Context.init(vm);
    lua.pushValue(state, 3);
    lua.remove(state, 2);
    decodeFieldValue(T, field_name, InnerType, state, &ctx) catch |err| {
        const msg = ctx.err orelse @errorName(err);
        lua.pushString(state, msg);
        ctx.deinit();
        return lua.raiseError(state);
    };
    ctx.deinit();
    return 0;
}

fn objectIndexTrampoline(comptime T: type) lua.CFunction {
    const methods = comptime ShapeData.methodsOf(T);
    const methods_type = comptime @TypeOf(methods);
    const has_custom_index = comptime @hasField(methods_type, "__index");
    const custom_trampoline = comptime if (has_custom_index) selectTrampoline(@field(methods, "__index"), "__index") else null;

    return struct {
        fn index(L: ?*lua.State) callconv(.c) c_int {
            if (lua.valueType(L.?, 2) == .string) {
                const key = lua.toString(L.?, 2) orelse return 0;

                if (std.mem.eql(u8, key, "__introspection")) {
                    lua.createTable(L.?, 0, 0);
                    var idx: i32 = 1;
                    inline for (@typeInfo(methods_type).@"struct".fields) |field| {
                        if (!std.mem.startsWith(u8, field.name, "__")) {
                            lua.pushString(L.?, field.name);
                            lua.setIndex(L.?, -2, idx);
                            idx += 1;
                        }
                    }
                    inline for (@typeInfo(T).@"struct".fields) |field| {
                    if (comptime Modifier.isFieldOrValue(field.type)) {
                            lua.pushString(L.?, field.name);
                            lua.setIndex(L.?, -2, idx);
                            idx += 1;
                        }
                    }
                    return 1;
                }

                inline for (@typeInfo(methods_type).@"struct".fields) |field| {
                    if (comptime !std.mem.startsWith(u8, field.name, "__")) {
                        if (std.mem.eql(u8, key, field.name)) {
                            const method_fn = comptime @field(methods, field.name);
                            lua.pushFunction(L.?, comptime selectTrampoline(method_fn, field.name));
                            return 1;
                        }
                    }
                }

                inline for (@typeInfo(T).@"struct".fields) |field| {
                    if (comptime Modifier.isFieldOrValue(field.type)) {
                        if (std.mem.eql(u8, key, field.name)) {
                            return fieldIndex(L, T, field.name);
                        }
                    }
                }
            }
            if (comptime has_custom_index) {
                return custom_trampoline.?(L);
            }
            return 0;
        }
    }.index;
}

fn objectNewIndexTrampoline(comptime T: type) lua.CFunction {
    const methods = comptime ShapeData.methodsOf(T);
    const methods_type = comptime @TypeOf(methods);
    const has_custom_newindex = comptime @hasField(methods_type, "__newindex");
    const custom_trampoline = comptime if (has_custom_newindex) selectTrampoline(@field(methods, "__newindex"), "__newindex") else null;

    return struct {
        fn newindex(L: ?*lua.State) callconv(.c) c_int {
            if (lua.valueType(L.?, 2) == .string) {
                const key = lua.toString(L.?, 2) orelse return 0;

                inline for (@typeInfo(T).@"struct".fields) |field| {
                    if (comptime Modifier.isFieldOrValue(field.type)) {
                        if (std.mem.eql(u8, key, field.name)) {
                            const state = L orelse unreachable;
                            if (comptime Modifier.isValue(field.type)) {
                                lua.pushString(state, "field '" ++ field.name ++ "' is read-only");
                                return lua.raiseError(state);
                            }
                            return fieldNewIndex(L, T, field.name, Modifier.innerType(field.type));
                        }
                    }
                }
            }
            if (comptime has_custom_newindex) {
                return custom_trampoline.?(L);
            }
            return 0;
        }
    }.newindex;
}

fn regularMethodCount(comptime T: type) i32 {
    const methods = comptime ShapeData.methodsOf(T);
    comptime var count: i32 = 0;
    inline for (@typeInfo(@TypeOf(methods)).@"struct".fields) |field| {
        if (!std.mem.startsWith(u8, field.name, "__")) count += 1;
    }
    return count;
}

fn objectFieldCount(comptime T: type) i32 {
    if (comptime @typeInfo(T) != .@"struct") return 0;
    comptime var count: i32 = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime Modifier.isFieldOrValue(field.type)) count += 1;
    }
    return count;
}

test {
    std.testing.refAllDecls(@This());
}
