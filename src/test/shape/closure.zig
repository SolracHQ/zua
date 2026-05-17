const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

const Counter = struct {
    count: i32,
    step: i32,
    pub const ZUA_SHAPE = Shape.Closure(Counter, tick, null, .{});
    fn tick(self: *Counter) i32 {
        self.count += self.step;
        return self.count;
    }
};

test "closure preserves state across calls" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .counter = Counter{ .count = 0, .step = 2 },
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\assert(counter() == 2)
        \\assert(counter() == 4)
        \\assert(counter() == 6)
    } });
}

const RangeIter = struct {
    start: usize,
    end: usize,
    step: usize,
    pub const ZUA_SHAPE = Shape.Closure(RangeIter, next, null, .{});

    fn next(state: *RangeIter, control: void, previous: ?usize) ?usize {
        _ = control;
        _ = previous;
        if (state.start >= state.end) return null;
        const current = state.start;
        state.start += state.step;
        return current;
    }
};

fn range(start: usize, end: usize, step: usize) RangeIter {
    return .{ .start = start, .end = end, .step = step };
}

test "iterator protocol via closure" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .range = range,
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\local values = {}
        \\for i in range(0, 10, 2) do
        \\    table.insert(values, i)
        \\end
        \\assert(#values == 5)
        \\assert(values[1] == 0)
        \\assert(values[3] == 4)
        \\assert(values[5] == 8)
    } });
}
