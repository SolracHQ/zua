const std = @import("std");
const zua = @import("zua");

const Zua = zua.Zua;
const Result = zua.Result;

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("f", zua.ZuaFn.from(fn_with_optional_args, .{ .parse_error = "f expects (i32, ?i32, ?i32)" }));

    const result = try z.eval(.{ i32, i32, i32 },
        \\return f(10), f(10, 5), f(10, 5, 2)
    );

    try std.testing.expectEqual(@as(i32, 10), result[0]);
    try std.testing.expectEqual(@as(i32, 15), result[1]);
    try std.testing.expectEqual(@as(i32, 17), result[2]);

    std.debug.print("Results: {d}, {d}, {d}\n", .{ result[0], result[1], result[2] });
}

fn fn_with_optional_args(_: *Zua, a: i32, b: ?i32, c: ?i32) Result(i32) {
    const b_value = if (b) |value| value else 0;
    const c_value = if (c) |value| value else 0;

    return Result(i32).ok(a + b_value + c_value);
}
