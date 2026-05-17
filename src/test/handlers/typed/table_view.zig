const std = @import("std");
const testing = std.testing;
const helpers = @import("../../helpers.zig");
const zua = @import("../../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

const Vector2 = struct {
    pub const ZUA_SHAPE = Shape.Table(Vector2, .{}, .{});
    x: f64,
    y: f64,
};

fn makeVector(x: f64, y: f64) Vector2 {
    return .{ .x = x, .y = y };
}

fn translate(ctx: *zua.Context, view: zua.Handlers.Typed.TableView(Vector2), delta_x: f64, delta_y: f64) !void {
    view.ref.x += delta_x;
    view.ref.y += delta_y;
    try view.sync(ctx);
}

test "TableView syncs mutations back to Lua table" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .make = Shape.Fn(makeVector, .{}),
        .translate = Shape.Fn(translate, .{}),
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\local v = make(3, 4)
        \\translate(v, 2, 1)
        \\assert(v.x == 5)
        \\assert(v.y == 5)
    } });
}
