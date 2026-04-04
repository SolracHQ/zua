const std = @import("std");
const zua = @import("zua");

const Result = zua.Result;
const Zua = zua.Zua;

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("add_ten", zua.ZuaFn.from(addTen, "add_ten expects (i32)"));

    const result = try z.eval(.{i32}, "return add_ten(32)");
    try std.testing.expectEqual(@as(i32, 42), result[0]);

    std.debug.print("Result: {d}\n", .{result[0]});
}

fn parseOneInt(value: i32) !i32 {
    return value;
}

fn addTen(_: *Zua, value: i32) !Result(i32) {
    return Result(i32).ok((try parseOneInt(value)) + 10);
}
