const std = @import("std");
const zua = @import("zua");

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa, init.io);
    defer z.deinit();

    try z.exec("print('Hello from Lua in Zig!')");

    const eval_result = try z.eval(.{i32}, "return 2 + 3");
    if (eval_result.failure) |fail| {
        std.debug.print("Error: {s}\n", .{fail.getErr()});
        return;
    }
    const result = eval_result.asOption() orelse unreachable;
    std.debug.print("2 + 3 = {}\n", .{result[0]});
}
