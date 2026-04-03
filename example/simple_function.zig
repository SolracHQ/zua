const std = @import("std");
const zua = @import("zua");

fn add(_: *zua.Zua, args: zua.Args) zua.Result(i32) {
    const parsed = args.parse(.{ i32, i32 }) catch return zua.Result(i32).errStatic("add expects (i32, i32)");

    return zua.Result(i32).ok(parsed[0] + parsed[1]);
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();
    globals.setFn("add", add);

    try z.exec(
        \\local result = add(20, 22)
        \\print(result)
    );
}
