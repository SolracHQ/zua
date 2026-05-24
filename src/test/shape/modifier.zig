const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

const Region = struct {
    pub const ZUA_SHAPE = Shape.Object(Region, .{}, .{});
    start: Shape.Modifier.Value(u64, .{ .description = "Start address." }),
    end: Shape.Modifier.Value(u64, .{ .description = "End address." }),
    hits: Shape.Modifier.Field(u32, .{ .description = "Hit counter." }),
};

fn makeRegion() Region {
    return .{
        .start = .new(0x1000),
        .end = .new(0x2000),
        .hits = .new(0),
    };
}

test "Modifier.Value and Field fields accessible from Lua" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .make_region = Shape.Fn(makeRegion, .{}),
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\local r = make_region()
        \\assert(r.start == 0x1000)
        \\assert(r["end"] == 0x2000)
        \\assert(r.hits == 0)
    } });
}
