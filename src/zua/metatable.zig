//! Metatable creation and attachment helpers for Zua values.
//!
//! This module builds metatables from Zua metadata, attaches them to userdata
//! values, and resolves method trampolines for both raw method functions and
//! wrapped `NativeFn`/`Closure` values.

const std = @import("std");
const lua = @import("../lua/lua.zig");
const Native = @import("functions/native.zig");
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
/// - state: The global Zua state owning the Lua VM and metatable cache.
/// - T: The type whose metatable should be attached.
pub fn attachMetatable(state: *State, comptime T: type) void {
    state.getOrCreateMetatable(T);
    _ = lua.setMetatable(state.luaState, -2);
}

/// Builds a metatable for `T` and leaves it on the Lua stack.
///
/// Regular methods are stored in the `__index` table, while metamethods are
/// written directly on the metatable. Object strategy types also receive a
/// `__name` field for diagnostic purposes.
///
/// Arguments:
/// - state: The global Zua state owning the Lua VM.
/// - T: The type whose metatable is being constructed.
pub fn buildMetatable(state: *State, comptime T: type) void {
    const strategy = Meta.strategyOf(T);

    lua.createTable(state.luaState, 0, 4);
    const mt_index = lua.absIndex(state.luaState, -1);

    if (strategy == .object) {
        lua.pushString(state.luaState, @typeName(T));
        lua.setField(state.luaState, mt_index, "__name");
    }

    const methods = comptime Meta.methodsOf(T);
    if (methodCount(T) == 0) return;

    const has_custom_index = comptime @hasField(@TypeOf(methods), "__index");
    const regular_count = comptime regularMethodCount(T);
    const methods_type = @TypeOf(methods);

    // Build the methods table (for regular named methods) when needed.
    // When a custom __index also exists, we generate a combined __index
    // trampoline.
    var methods_index: i32 = 0;
    if (regular_count > 0) {
        lua.createTable(state.luaState, 0, regular_count);
        methods_index = lua.absIndex(state.luaState, -1);
    }

    inline for (@typeInfo(methods_type).@"struct".fields) |field| {
        // Skip __index —since it is handled separately below.
        if (comptime std.mem.eql(u8, field.name, "__index")) continue;

        const method_fn = @field(methods, field.name);
        lua.pushFunction(state.luaState, selectTrampoline(method_fn));

        if (comptime std.mem.startsWith(u8, field.name, "__")) {
            lua.setField(state.luaState, mt_index, field.name);
        } else {
            lua.setField(state.luaState, methods_index, field.name);
        }
    }

    if (regular_count > 0 and has_custom_index) {
        // when needs both __index (for methods and custom __index) use a combined trampoline that tries with named methods first, then falls back to the custom __index.
        lua.pushFunction(state.luaState, combinedIndexTrampoline(T));
        lua.setField(state.luaState, mt_index, "__index");
        // The methods table is no longer needed as __index so lets pop it.
        lua.pop(state.luaState, 1);
    } else if (regular_count > 0) {
        // No custom __index: the methods table itself is __index.
        lua.setField(state.luaState, mt_index, "__index");
    } else if (has_custom_index) {
        // Only a custom __index, no named methods.
        lua.pushFunction(state.luaState, selectTrampoline(@field(methods, "__index")));
        lua.setField(state.luaState, mt_index, "__index");
    }
}

/// Selects the Lua C function trampoline for a method value.
///
/// If the method is already a compiled callback wrapper, its trampoline is returned
/// directly. Otherwise the method function is wrapped in a new `NativeFn` so it can
/// be exposed to Lua with the standard decode/execute semantics.
fn selectTrampoline(comptime method_fn: anytype) lua.CFunction {
    const method_fn_type = @TypeOf(method_fn);

    // Check if method_fn is a precompiled callback wrapper (has __IsZuaNativeFunction marker)
    if (comptime @typeInfo(method_fn_type) == .@"struct" and @hasDecl(method_fn_type, "__IsZuaNativeFunction")) {
        return method_fn_type.trampoline();
    }

    return Native.NativeFn(method_fn, .{}).trampoline();
}

/// Generates a combined __index trampoline for types that have both regular
/// named methods and a custom __index handler.
///
/// This trampoline first checks if the key matches any regular method names, and if so dispatches to the corresponding method. If not, it falls back to the custom
/// __index handler
fn combinedIndexTrampoline(comptime T: type) lua.CFunction {
    const methods = comptime Meta.methodsOf(T);
    const methods_type = comptime @TypeOf(methods);
    const custom_trampoline = comptime selectTrampoline(@field(methods, "__index")).?;

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
                    return 1;
                }
                inline for (@typeInfo(methods_type).@"struct".fields) |field| {
                    if (comptime !std.mem.startsWith(u8, field.name, "__")) {
                        if (std.mem.eql(u8, key, field.name)) {
                            const method_fn = comptime @field(methods, field.name);
                            lua.pushFunction(L.?, comptime selectTrampoline(method_fn));
                            return 1;
                        }
                    }
                }
            }
            return custom_trampoline(L);
        }
    }.index;
}

/// Returns the total number of methods declared on `T`.
fn methodCount(comptime T: type) i32 {
    const methods = comptime Meta.methodsOf(T);
    return @intCast(@typeInfo(@TypeOf(methods)).@"struct".fields.len);
}

/// Returns the number of non-metamethods (those not starting with `__`) on `T`.
///
/// This determines whether a separate `__index` table needs to be built.
fn regularMethodCount(comptime T: type) i32 {
    const methods = comptime Meta.methodsOf(T);
    comptime var count: i32 = 0;
    inline for (@typeInfo(@TypeOf(methods)).@"struct".fields) |field| {
        if (!std.mem.startsWith(u8, field.name, "__")) count += 1;
    }
    return count;
}

test {
    std.testing.refAllDecls(@This());
}
