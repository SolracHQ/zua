const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

const Point = struct {
    pub const ZUA_SHAPE = Shape.Table(Point, .{}, .{});
    x: f64,
    y: f64,
};

fn makePoint(x: f64, y: f64) Point {
    return .{ .x = x, .y = y };
}

fn doublePoint(p: Point) Point {
    return .{ .x = p.x * 2, .y = p.y * 2 };
}

test "Shape.Table struct round-trips through Lua" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .point = Shape.Fn(makePoint, .{}),
        .double = Shape.Fn(doublePoint, .{}),
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\local p = point(3, 4)
        \\assert(p.x == 3)
        \\assert(p.y == 4)
        \\local d = double(p)
        \\assert(d.x == 6)
        \\assert(d.y == 8)
    } });
}
