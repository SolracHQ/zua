const std = @import("std");
const zua = @import("zua");

const Counter = struct {
    pub const ZUA_SHAPE = zua.Shape.Object(Counter, .{
        .value = getValue,
        .increment = zua.Shape.Fn(increment, .{}),
        .reset = reset,
        .__tostring = toString,
    }, .{});

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

    pub const ZUA_SHAPE = zua.Shape.TypedAlias(Condition, .{}, .{});
};

const Region = struct {
    pub const ZUA_SHAPE = zua.Shape.Object(Region, .{
        .__tostring = toString,
    }, .{ .name = "Region" });

    start: zua.Shape.Modifier.Value(u64, .{ .description = "Start address." }),
    end: zua.Shape.Modifier.Value(u64, .{ .description = "End address." }),
    hits: zua.Shape.Modifier.Field(u32, .{ .description = "Hit counter." }),

    fn toString(ctx: *zua.Context, self: *Region) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena(), "Region(0x{x}, 0x{x}, hits={})", .{ self.start.value, self.end.value, self.hits.value }) catch
            try ctx.failTyped([]const u8, "out of memory");
    }
};

fn makeRegion() Region {
    return Region{
        .start = .{ .value = 0x1000 },
        .end = .{ .value = 0x2000 },
        .hits = .{ .value = 0 },
    };
}

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

fn makeCounter() Counter {
    return Counter{};
}

pub fn main(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();
    var ctx = zua.Context.init(state);
    defer ctx.deinit();
    var executor = zua.Executor{};

    try state.addGlobals(&ctx, .{
        .Counter = makeCounter,
        .makeEqCondition = makeEqCondition,
        .makeRangeCondition = makeRangeCondition,
        .describeCondition = describeCondition,
        .makeRegion = makeRegion,
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
        \\
        \\-- Object with Field/Value markers
        \\local r = makeRegion()
        \\print("Region:", tostring(r))
        \\print("start:", r.start, r["end"], "hits:", r.hits)
        \\r.hits = 42
        \\print("After setting hits:", tostring(r))
    } });
}
