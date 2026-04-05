const std = @import("std");
const zua = @import("zua");

const Result = zua.Result;

const Counter = struct {
    pub const ZUA_META = zua.meta.Object(Counter, .{
        .value = getValue,
        .increment = zua.ZuaFn.pure(increment, .{ .parse_error = "increment expects an integer amount" }),
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

fn makeCounter(_: *zua.Zua) Result(Counter) {
    return Result(Counter).ok(Counter{});
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("Counter", zua.ZuaFn.from(makeCounter, .{}));

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
    );
}
