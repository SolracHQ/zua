//! Metatable creation and attachment for Zua values.
//!
//! Builds metatables from `ZUA_SHAPE` declarations, wires methods and
//! metamethods, and attaches them to userdata values.
const std = @import("std");
const lua = @import("../../lua/lua.zig");
const ShapeData = @import("../shape/shape_data.zig");
const Shape = @import("../shape/api.zig");
const Modifier = @import("../shape/modifier.zig");
const Marker = @import("../marker.zig").Marker;
const State = @import("../state.zig");
const Context = @import("../context.zig");
const Mapper = @import("../mapper/api.zig");
const Trampoline = @import("trampoline.zig");
const Count = @import("count.zig");
const Index = @import("index.zig");
const NewIndex = @import("newindex.zig");

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
    const regular_count = comptime Count.regularMethodCount(T);
    const field_count = comptime Count.objectFieldCount(T);
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
        lua.pushFunction(state.luaState, Trampoline.selectTrampoline(method_fn, field.name));

        if (comptime std.mem.startsWith(u8, field.name, "__")) {
            lua.setField(state.luaState, mt_index, field.name);
        } else {
            lua.setField(state.luaState, methods_index, field.name);
        }
    }

    const needs_index = regular_count > 0 or has_fields or has_custom_index;
    if (needs_index) {
        lua.pushFunction(state.luaState, Index.objectIndexTrampoline(T));
        lua.setField(state.luaState, mt_index, "__index");
    }

    const needs_newindex = has_fields or has_custom_newindex;
    if (needs_newindex) {
        lua.pushFunction(state.luaState, NewIndex.objectNewIndexTrampoline(T));
        lua.setField(state.luaState, mt_index, "__newindex");
    }

    if (needs_index and regular_count > 0) {
        lua.pop(state.luaState, 1);
    }
}

test {
    std.testing.refAllDecls(@This());
}
