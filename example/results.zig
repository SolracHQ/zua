const std = @import("std");
const zua = @import("zua");

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();
    globals.set("base", 20);

    const parsed = try z.eval(.{ i32, i32, []const u8 },
        \\return base + 1, base + 2, "done"
    );
    std.debug.print("first={d} second={d} label={s}\n", .{ parsed[0], parsed[1], parsed[2] });
}
