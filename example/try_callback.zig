const std = @import("std");
const zua = @import("zua");

const Args = zua.Args;
const Result = zua.Result;
const Zua = zua.Zua;

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("add_ten", addTen);

    const result = try z.eval(.{i32}, "return add_ten(32)");
    try std.testing.expectEqual(@as(i32, 42), result[0]);

    std.debug.print("Result: {d}\n", .{result[0]});
}

fn parseOneInt(args: Args) !i32 {
    const parsed = try args.parse(.{i32});
    return parsed[0];
}

fn addTen(_: *Zua, args: Args) !Result(i32) {
    const value = try parseOneInt(args);
    return Result(i32).ok(value + 10);
}