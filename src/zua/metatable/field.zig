//! Read/write access to `Field`/`Value`-declared struct fields from Lua.

const std = @import("std");
const lua = @import("../../lua/lua.zig");
const State = @import("../state.zig");
const Context = @import("../context.zig");
const Mapper = @import("../mapper/api.zig");
const ObjectGuard = @import("../mapper/object_guard.zig");

/// Encodes `self.field_name` onto the Lua stack via the mapper.
fn pushFieldValue(comptime T: type, comptime field_name: []const u8, state: *lua.State, ctx: *Context) !void {
    const raw = lua.toUserdata(state, 1) orelse return;
    const self_ptr = try ObjectGuard.ObjectGuard(T).from(ctx, raw);
    try Mapper.Encoder.push(ctx, @field(self_ptr.*, field_name).value);
}

/// Decodes a Lua value into `self.field_name` via the mapper.
fn decodeFieldValue(comptime T: type, comptime field_name: []const u8, comptime InnerType: type, state: *lua.State, ctx: *Context) !void {
    const val = try Mapper.Decoder.pop(ctx, InnerType);
    const raw = lua.toUserdata(state, 1) orelse return;
    const self_ptr = try ObjectGuard.ObjectGuard(T).from(ctx, raw);
    @field(self_ptr.*, field_name).value = val;
}

/// Lua CFunction: pushes the value of `field_name` from the userdata at stack index 1 onto the stack.
pub fn fieldIndex(L: ?*lua.State, comptime T: type, comptime field_name: []const u8) c_int {
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

/// Lua CFunction: pops a value from the stack and writes it into `field_name` on the userdata at stack index 1.
pub fn fieldNewIndex(L: ?*lua.State, comptime T: type, comptime field_name: []const u8, comptime InnerType: type) c_int {
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
