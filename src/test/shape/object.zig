const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");
const Executor = zua.Executor;

const Counter = struct {
    pub const ZUA_SHAPE = zua.Shape.Object(Counter, .{
        .value = getValue,
        .increment = increment,
    }, .{});
    count: i32,

    fn getValue(self: *Counter) i32 {
        return self.count;
    }

    fn increment(self: *Counter, amount: i32) void {
        self.count += amount;
    }
};

fn makeCounter() Counter {
    return .{ .count = 0 };
}

test "Shape.Object with methods callable from Lua" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .Counter = makeCounter,
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\local c = Counter()
        \\assert(c:value() == 0)
        \\c:increment(5)
        \\assert(c:value() == 5)
        \\c:increment(3)
        \\assert(c:value() == 8)
    } });
}
