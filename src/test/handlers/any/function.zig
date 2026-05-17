const std = @import("std");
const testing = std.testing;
const helpers = @import("../../helpers.zig");
const zua = @import("../../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

fn applyTwice(ctx: *zua.Context, callback: zua.Handlers.Any.Function, initial: i32) !i32 {
    var current = initial;
    current = try callback.call(ctx, .{current}, i32);
    current = try callback.call(ctx, .{current}, i32);
    return current;
}

test "calling a Lua function from Zig via Any.Function" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .apply_twice = Shape.Fn(applyTwice, .{}),
    });
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, i32, .{ .code = .{ .string =
        \\local increment = function(x) return x + 1 end
        \\return apply_twice(increment, 5)
    } });
    try testing.expectEqual(7, result);
}
