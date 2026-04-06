const std = @import("std");
const zua = @import("zua");

const Result = zua.Result;

fn add(a: i32, b: i32) Result(i32) {
    return Result(i32).ok(a + b);
}

fn greet(z: *zua.Zua, name: []const u8) Result([]const u8) {
    const display = std.fmt.allocPrint(
        z.allocator,
        "Hello, {s}!",
        .{name},
    ) catch return Result([]const u8).errStatic("out of memory");
    return Result([]const u8).owned(display);
}

fn safeDivide(_: *zua.Zua, a: f64, b: f64) Result(f64) {
    if (b == 0.0) {
        return Result(f64).errStatic("division by zero");
    }
    return Result(f64).ok(a / b);
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa, init.io);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("add", zua.ZuaFn.pure(add, .{ .parse_error = "add expects (number, number)" }));
    globals.setFn("greet", zua.ZuaFn.from(greet, .{ .parse_error = "greet expects (string)" }));
    globals.setFn("divide", zua.ZuaFn.from(safeDivide, .{ .parse_error = "divide expects (number, number)" }));

    try z.exec(
        \\print("add(10, 20) =", add(10, 20))
        \\print(greet("Zig"))
        \\print("divide(10, 2) =", divide(10, 2))
        \\
        \\-- Error handling example
        \\local ok, result = pcall(divide, 10, 0)
        \\if not ok then
        \\    print("Error:", result)
        \\end
    );
}
