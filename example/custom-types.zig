const std = @import("std");
const zua = @import("zua");

const Counter = struct {
    pub const ZUA_META = zua.Meta.Object(Counter, .{
        .value = getValue,
        .increment = zua.Native.new(increment, .{ .parse_err_fmt = "increment expects an integer amount: {s}" }),
        .reset = reset,
        .__tostring = toString,
    });

    count: i32 = 0,

    pub fn getValue(self: *Counter) i32 {
        return self.count;
    }

    pub fn increment(self: *Counter, amount: i32) void {
        self.count += amount;
    }

    pub fn reset(self: *Counter) void {
        self.count = 0;
    }

    pub fn toString(ctx: *zua.Context, self: *Counter) ![]const u8 {
        return std.fmt.allocPrint(
            ctx.arena(),
            "Counter({d})",
            .{self.count},
        ) catch try ctx.failTyped([]const u8, "out of memory");
    }
};

const Range = struct {
    min: f64,
    max: f64,
};

const Condition = union(enum) {
    eq: f64,
    in_range: Range,

    pub const ZUA_META = zua.Meta.Table(Condition, .{});
};

fn makeEqCondition(value: f64) Condition {
    return .{ .eq = value };
}

fn makeRangeCondition(min: f64, max: f64) Condition {
    return .{ .in_range = Range{ .min = min, .max = max } };
}

fn describeCondition(ctx: *zua.Context, cond: Condition) ![]const u8 {
    return switch (cond) {
        .eq => |value| std.fmt.allocPrint(ctx.arena(), "eq {d}", .{value}),
        .in_range => |range| std.fmt.allocPrint(ctx.arena(), "in_range {{ min = {d}, max = {d} }}", .{ range.min, range.max }),
    } catch try ctx.failTyped([]const u8, "out of memory");
}

fn makeCounter(_: *zua.Context) Counter {
    return Counter{};
}

pub fn main(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();
    var executor = zua.Executor{};
    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    try state.addGlobals(&ctx, .{
        .Counter = makeCounter,
        .makeEqCondition = makeEqCondition,
        .makeRangeCondition = makeRangeCondition,
        .describeCondition = describeCondition,
    });

    try executor.execute(&ctx, .{ .code = .{ .string =
        \\local c = Counter()
        \\print("Initial:", c:value())
        \\
        \\c:increment(5)
        \\print("After increment(5):", c:value())
        \\
        \\c:increment(3)
        \\print("After increment(3):", c:value())
        \\
        \\print("As string:", tostring(c))
        \\
        \\c:reset()
        \\print("After reset:", c:value())
        \\
        \\print("Condition eq:", describeCondition(makeEqCondition(8.3)))
        \\print("Condition range:", describeCondition(makeRangeCondition(0, 255)))
        \\print("Condition from Lua table:", describeCondition({ eq = 8.3 }))
    } });
}
