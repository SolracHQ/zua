const std = @import("std");
const zua = @import("zua");

fn increment(_: *zua.Zua, counter: zua.Table, delta: i32) zua.Result(i32) {
    const next_value = (counter.get("count", i32) catch return zua.Result(i32).errStatic("counter.count missing")) + delta;
    counter.set("count", next_value);
    return zua.Result(i32).ok(next_value);
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    const counter = z.createTable(0, 2);
    counter.set("count", 0);
    counter.setFn("increment", zua.ZuaFn.from(increment, "counter:increment expects (self, i32)"));
    globals.set("counter", counter);
    counter.pop();

    try z.exec(
        \\local value = counter:increment(5)
        \\print(value)
        \\print(counter.count)
    );
}
