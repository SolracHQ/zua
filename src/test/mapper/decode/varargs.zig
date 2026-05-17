const std = @import("std");
const testing = std.testing;
const helpers = @import("../../helpers.zig");
const zua = @import("../../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

fn sumAll(ctx: *zua.Context, args: zua.Mapper.VarArgs) !i64 {
    var total: i64 = 0;
    for (args.args) |prim| {
        switch (prim) {
            .integer => |i| total += i,
            .float => |f| total += @intFromFloat(f),
            else => return ctx.failTyped(i64, "expected number"),
        }
    }
    return total;
}

test "VarArgs sums multiple Lua arguments" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .sum = Shape.Fn(sumAll, .{}),
    });
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, i64, .{ .code = .{ .string =
        \\return sum(1, 2, 3, 4, 5)
    } });
    try testing.expectEqual(@as(i64, 15), result);
}

test "VarArgs with zero arguments returns zero" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .sum = Shape.Fn(sumAll, .{}),
    });
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, i64, .{ .code = .{ .string =
        \\return sum()
    } });
    try testing.expectEqual(@as(i64, 0), result);
}
