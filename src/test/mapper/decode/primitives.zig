const std = @import("std");
const testing = std.testing;
const helpers = @import("../../helpers.zig");
const zua = @import("../../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

fn safeDivide(ctx: *zua.Context, a: f64, b: f64) !f64 {
    if (b == 0.0) {
        return ctx.failTyped(f64, "division by zero");
    }
    return a / b;
}

test "failTyped returns error caught by pcall" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .divide = Shape.Fn(safeDivide, .{}),
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\local ok, result = pcall(divide, 10, 0)
        \\assert(not ok)
        \\assert(type(result) == "string")
    } });
}

test "safe divide succeeds with valid inputs" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .divide = Shape.Fn(safeDivide, .{}),
    });
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, f64, .{ .code = .{ .string =
        \\return divide(10, 2)
    } });
    try testing.expectEqual(@as(f64, 5.0), result);
}
