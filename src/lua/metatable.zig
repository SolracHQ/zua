const std = @import("std");
const lua = @import("lua.zig");
const translation = @import("translation.zig");
const ZuaFn = @import("zua_fn.zig");
const Zua = @import("zua.zig").Zua;

pub fn attachMetatable(z: *Zua, comptime T: type) void {
    z.getOrCreateMetatable(T);
    _ = lua.setMetatable(z.state, -2);
}

pub fn buildMetatable(z: *Zua, comptime T: type) void {
    const strategy = translation.strategyOf(T);

    lua.createTable(z.state, 0, 4);
    const mt_index = lua.absIndex(z.state, -1);

    if (strategy == .object) {
        lua.pushString(z.state, @typeName(T));
        lua.setField(z.state, mt_index, "__name");
    }

    if (!@hasDecl(T, "ZUA_METHODS")) return;

    lua.createTable(z.state, 0, methodCount(T));
    const methods_index = lua.absIndex(z.state, -1);

    const methods_type = @TypeOf(T.ZUA_METHODS);

    inline for (@typeInfo(methods_type).@"struct".fields) |field| {
        const method_fn = @field(T.ZUA_METHODS, field.name);
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
    const fn_info = @typeInfo(@TypeOf(method_fn)).@"fn";
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
    return @intCast(@typeInfo(@TypeOf(T.ZUA_METHODS)).@"struct".fields.len);
}
