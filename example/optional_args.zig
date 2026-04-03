const std = @import("std");
const zua = @import("zua");

const Zua = zua.Zua;
const Args = zua.Args;
const Result = zua.Result;
const Table = zua.Table;

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("f", fn_with_optional_args);

    const result = try z.eval(.{ i32, i32, i32 },
        \\return f(10), f(10, 5), f(10, 5, 2)
    );

    try std.testing.expectEqual(@as(i32, 10), result[0]);
    try std.testing.expectEqual(@as(i32, 15), result[1]);
    try std.testing.expectEqual(@as(i32, 17), result[2]);

    std.debug.print("Results: {d}, {d}, {d}\n", .{ result[0], result[1], result[2] });
}

fn fn_with_optional_args(z: *Zua, args: Args) Result(.{i32}) {
    _ = z;
    const parsed = args.parse(.{ i32, ?i32, ?i32 }) catch |err| {
        return Result(.{i32}).errZig(err);
    };

    const a = parsed[0];
    const b = if (parsed[1]) |v| v else 0;
    const c = if (parsed[2]) |v| v else 0;

    return Result(.{i32}).ok(.{a + b + c});
}
