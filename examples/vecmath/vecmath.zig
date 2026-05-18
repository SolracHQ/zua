const std = @import("std");
const zua = @import("zua");
const lua = zua.Bindings.lua;

// Lua dylib entry point for require("vecmath").
//
// When Lua calls require("vecmath") it opens this shared library and calls
// luaopen_vecmath. The function receives the raw lua_State pointer and must
// push the module table onto the Lua stack.
//
// State.libState attaches zua to the existing lua_State. This is the
// embedding path, different from State.init which creates a fresh VM.
//
// The Vecmath{} instance is pushed via Mapper.Encoder.push, which
// reads its ZUA_SHAPE and encodes each field (vec2, vec3, lerp, etc.)
// as named entries in a Lua table. The table is what require returns.
//
// See lib/module.zig for the module definition.

const Vecmath = @import("lib/module.zig").Vecmath;

export fn luaopen_vecmath(L: *lua.State) c_int {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    const io = threaded.io();

    const state = zua.State.libState(L, std.heap.c_allocator, io, "vecmath") catch return 0;
    var ctx = zua.Context.init(state);
    defer ctx.deinit();
    zua.Mapper.Encoder.push(&ctx, Vecmath{}) catch return 0;
    return 1;
}
