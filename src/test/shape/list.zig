const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

const IntList = struct {
    pub const ZUA_SHAPE = Shape.List(IntList, getElements, .{
        .sum = sum,
        .__tostring = toString,
    }, .{});

    items: [3]i32,

    fn getElements(self: *IntList) []const i32 {
        return self.items[0..];
    }

    fn sum(self: *IntList) i32 {
        var total: i32 = 0;
        for (self.items) |v| total += v;
        return total;
    }

    fn toString(ctx: *zua.Context, self: *IntList) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena(), "IntList({d})", .{self.items.len}) catch
            ctx.failTyped([]const u8, "oom");
    }
};

fn makeList(a: i32, b: i32, c: i32) IntList {
    return IntList{ .items = .{ a, b, c } };
}

test "Shape.List indexing, length, and methods" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .make = Shape.Fn(makeList, .{}),
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\local list = make(10, 20, 30)
        \\assert(#list == 3)
        \\assert(list[1] == 10)
        \\assert(list[2] == 20)
        \\assert(list[3] == 30)
        \\assert(list:sum() == 60)
        \\assert(tostring(list) == "IntList(3)")
    } });
}
