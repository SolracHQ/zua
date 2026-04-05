const std = @import("std");
const zua = @import("zua");

fn add(_: *zua.Zua, a: i32, b: i32) zua.Result(i32) {
    return zua.Result(i32).ok(a + b);
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();
    globals.setFn("add", zua.ZuaFn.from(add, .{ .parse_error = "add expects (i32, i32)" }));

    try z.exec(
        \\local result = add(20, 22)
        \\print(result)
    );
}
