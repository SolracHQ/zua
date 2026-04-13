const std = @import("std");
const zua = @import("zua");

pub fn main(init: std.process.Init) !void {
    const z = try zua.State.init(init.gpa, init.io);
    defer z.deinit();
    var executor = zua.Executor{};
    var ctx = zua.Context.init(z);
    defer ctx.deinit();

    try executor.execute(&ctx, .{ .code = .{ .string = "print('Hello from Lua in Zig!')" } });

    const result = try executor.eval(&ctx, i32, .{ .code = .{ .string = "return 2 + 3" } });
    std.debug.print("2 + 3 = {}\n", .{result});
}
