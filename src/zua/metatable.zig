//! Metatable creation and attachment helpers for Zua values.
//!
//! This module builds metatables from Zua metadata, attaches them to userdata
//! values, and resolves method trampolines for both raw method functions and
//! wrapped `ZuaFn` values.

const std = @import("std");
const lua = @import("../lua/lua.zig");
const ZuaFn = @import("functions/zua_fn.zig");
const Meta = @import("meta.zig");
const State = @import("state/state.zig");
const Context = @import("state/context.zig");

/// Ensures the metatable for `T` exists and attaches it to the value on top of the Lua stack.
///
/// This is used by the encoder when pushing userdata values with an object
/// strategy. It creates or reuses a cached metatable and sets it on the value
/// currently at the top of the Lua stack.
///
/// Arguments:
/// - z: The global Zua state owning the Lua VM and metatable cache.
/// - T: The type whose metatable should be attached.
pub fn attachMetatable(z: *State, comptime T: type) void {
    z.getOrCreateMetatable(T);
    _ = lua.setMetatable(z.luaState, -2);
}

/// Builds a metatable for `T` and leaves it on the Lua stack.
///
/// Regular methods are stored in the `__index` table, while metamethods are
/// written directly on the metatable. Object strategy types also receive a
/// `__name` field for diagnostic purposes.
///
/// Arguments:
/// - z: The global Zua state owning the Lua VM.
/// - T: The type whose metatable is being constructed.
pub fn buildMetatable(z: *State, comptime T: type) void {
    const strategy = Meta.getMeta(T).strategy;

    lua.createTable(z.luaState, 0, 4);
    const mt_index = lua.absIndex(z.luaState, -1);

    if (strategy == .object) {
        lua.pushString(z.luaState, @typeName(T));
        lua.setField(z.luaState, mt_index, "__name");
    }

    const methods = comptime Meta.getMeta(T).methods;
    if (methodCount(T) == 0) return;

    lua.createTable(z.luaState, 0, methodCount(T));
    const methods_index = lua.absIndex(z.luaState, -1);

    const methods_type = @TypeOf(methods);

    inline for (@typeInfo(methods_type).@"struct".fields) |field| {
        const method_fn = @field(methods, field.name);
        const trampoline = selectTrampoline(method_fn);
        lua.pushFunction(z.luaState, trampoline);

        // Metamethods (starting with __) go directly on the metatable
        if (comptime std.mem.startsWith(u8, field.name, "__")) {
            lua.setField(z.luaState, mt_index, field.name);
        } else {
            lua.setField(z.luaState, methods_index, field.name);
        }
    }

    lua.setField(z.luaState, mt_index, "__index");
}

/// Selects the Lua C function trampoline for a method value.
///
/// If the method is already a compiled `ZuaFn`, its trampoline is returned
/// directly. Otherwise the method function is wrapped in a new `ZuaFn` so it can
/// be exposed to Lua with the standard decode/execute semantics.
fn selectTrampoline(comptime method_fn: anytype) lua.CFunction {
    const method_fn_type = @TypeOf(method_fn);

    // Check if method_fn is a ZuaFn (has __IsZuaFn marker)
    if (comptime @typeInfo(method_fn_type) == .@"struct" and @hasDecl(method_fn_type, "__IsZuaFn")) {
        return method_fn_type.trampoline();
    }

    return ZuaFn.ZuaFnType(method_fn, .{}).trampoline();
}

/// Returns the number of methods declared on `T`.
///
/// This is used to size the temporary `__index` table before populating it.
fn methodCount(comptime T: type) i32 {
    const methods = comptime Meta.getMeta(T).methods;
    return @intCast(@typeInfo(@TypeOf(methods)).@"struct".fields.len);
}
