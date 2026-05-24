const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;
const lua = zua.Bindings.lua;

fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn ping() void {}

test "addGlobals with bare function" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .ping = ping,
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\ping()
    } });
}

test "addGlobals with Shape.Fn wrapper" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .add = Shape.Fn(add, .{}),
    });
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, i32, .{ .code = .{ .string =
        \\return add(10, 20)
    } });
    try testing.expectEqual(30, result);
}

test "addGlobals adds string constant readable from Lua" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .message = "hello zig",
    });
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, []const u8, .{ .code = .{ .string =
        \\return message
    } });
    try testing.expectEqualStrings("hello zig", result);
}

test "pushTop and popTop restore stack position" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    const lua_state = test_env.state.luaState;
    _ = lua.getTop(lua_state); // consume any pre-existing stack (should be 0)

    test_env.state.pushTop();
    defer test_env.state.popTop();

    lua.pushInteger(lua_state, 1);
    lua.pushInteger(lua_state, 2);
    lua.pushInteger(lua_state, 3);
    try testing.expectEqual(@as(i32, 3), lua.getTop(lua_state));
    // popTop in defer restores to 0
}
