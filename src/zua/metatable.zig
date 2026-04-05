const std = @import("std");
const lua = @import("../lua/lua.zig");
const translation = @import("translation.zig");
const ZuaFn = @import("zua_fn.zig");
const Meta = @import("meta.zig");
const Zua = @import("zua.zig").Zua;

/// Ensures the metatable for `T` exists and attaches it to the value on top of the Lua stack.
pub fn attachMetatable(z: *Zua, comptime T: type) void {
    z.getOrCreateMetatable(T);
    _ = lua.setMetatable(z.state, -2);
}

/// Builds a metatable for `T` and leaves it on the Lua stack.
/// Regular methods are written to `__index`, while metamethods are written directly to the metatable.
pub fn buildMetatable(z: *Zua, comptime T: type) void {
    const strategy = Meta.strategyOf(T);

    lua.createTable(z.state, 0, 4);
    const mt_index = lua.absIndex(z.state, -1);

    if (strategy == .object) {
        lua.pushString(z.state, @typeName(T));
        lua.setField(z.state, mt_index, "__name");
    }

    const methods = comptime Meta.methodsOf(T);
    if (methods == null) return;

    lua.createTable(z.state, 0, methodCount(T));
    const methods_index = lua.absIndex(z.state, -1);

    const methods_type = @TypeOf(methods.?);

    inline for (@typeInfo(methods_type).@"struct".fields) |field| {
        const method_fn = @field(methods.?, field.name);
        const trampoline = selectTrampoline(method_fn);
        lua.pushFunction(z.state, trampoline);

        // Metamethods (starting with __) go directly on the metatable
        if (comptime std.mem.startsWith(u8, field.name, "__")) {
            lua.setField(z.state, mt_index, field.name);
        } else {
            lua.setField(z.state, methods_index, field.name);
        }
    }

    lua.setField(z.state, mt_index, "__index");
}

fn selectTrampoline(comptime method_fn: anytype) lua.CFunction {
    const method_fn_type = @TypeOf(method_fn);

    // Check if method_fn is a ZuaFn (has __IsZuaFn marker)
    if (comptime @typeInfo(method_fn_type) == .@"struct" and @hasDecl(method_fn_type, "__IsZuaFn")) {
        return method_fn_type.trampoline();
    }

    // Otherwise wrap it
    const fn_info = @typeInfo(method_fn_type).@"fn";
    const first_param = fn_info.params[0].type orelse
        @compileError("method parameters must have concrete types");

    const error_config = ZuaFn.ZuaFnErrorConfig{};

    if (first_param == *Zua) {
        return @TypeOf(ZuaFn.from(method_fn, error_config)).trampoline();
    } else {
        return @TypeOf(ZuaFn.pure(method_fn, error_config)).trampoline();
    }
}

fn methodCount(comptime T: type) i32 {
    const methods = comptime Meta.methodsOf(T);
    if (methods == null) return 0;
    return @intCast(@typeInfo(@TypeOf(methods.?)).@"struct".fields.len);
}
