const std = @import("std");
const zua = @import("zua");

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    try z.exec("print('Hello from Lua in Zig!')");

    const result = try z.eval(.{i32}, "return 2 + 3");
    std.debug.print("2 + 3 = {}\n", .{result[0]});
}
