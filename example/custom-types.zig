const std = @import("std");
const zua = @import("zua");

const Result = zua.Result;

const Counter = struct {
    pub const ZUA_META = zua.meta.Object(Counter, .{
        .value = getValue,
        .increment = zua.ZuaFn.pure(increment, .{ .parse_err_fmt = "increment expects an integer amount: {s}" }),
        .reset = reset,
        .__tostring = toString,
    });

    count: i32 = 0,

    pub fn getValue(self: *Counter) Result(i32) {
        return Result(i32).ok(self.count);
    }

    pub fn increment(self: *Counter, amount: i32) Result(.{}) {
        self.count += amount;
        return Result(.{}).ok(.{});
    }

    pub fn reset(self: *Counter) Result(.{}) {
        self.count = 0;
        return Result(.{}).ok(.{});
    }

    pub fn toString(z: *zua.Zua, self: *Counter) Result([]const u8) {
        const display = std.fmt.allocPrint(
            z.allocator,
            "Counter({d})",
            .{self.count},
        ) catch return Result([]const u8).errStatic("out of memory");
        return Result([]const u8).owned(display);
    }
};

const Range = struct {
    min: f64,
    max: f64,
};

const Condition = union(enum) {
    eq: f64,
    in_range: Range,

    pub const ZUA_META = zua.meta.Table(Condition, .{});
};

fn makeEqCondition(value: f64) Result(Condition) {
    return Result(Condition).ok(.{ .eq = value });
}

fn makeRangeCondition(min: f64, max: f64) Result(Condition) {
    return Result(Condition).ok(.{ .in_range = Range{ .min = min, .max = max } });
}

fn describeCondition(z: *zua.Zua, cond: Condition) Result([]const u8) {
    const description = switch (cond) {
        .eq => |value| std.fmt.allocPrint(z.allocator, "eq {d}", .{value}),
        .in_range => |range| std.fmt.allocPrint(z.allocator, "in_range {{ min = {d}, max = {d} }}", .{ range.min, range.max }),
    } catch return Result([]const u8).errStatic("out of memory");

    return Result([]const u8).owned(description);
}

fn makeCounter(_: *zua.Zua) Result(Counter) {
    return Result(Counter).ok(Counter{});
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa, init.io);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("Counter", zua.ZuaFn.from(makeCounter, .{}));
    globals.setFn("makeEqCondition", zua.ZuaFn.pure(makeEqCondition, .{}));
    globals.setFn("makeRangeCondition", zua.ZuaFn.pure(makeRangeCondition, .{}));
    globals.setFn("describeCondition", zua.ZuaFn.from(describeCondition, .{}));

    try z.exec(
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
    );
}
