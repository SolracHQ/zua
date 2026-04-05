const std = @import("std");
const zua = @import("zua");

const TraceBackResult = zua.Zua.TraceBackResult;
const Result = zua.Result;
const ZuaFn = zua.ZuaFn;
const Error = error{InvalidValue};

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    const fail_fn = ZuaFn.pure(fail, .{ .parse_error = "fail expects (i32)", .zig_err_fmt = "fail failed with error: {s}" });
    globals.setFn("fail", fail_fn);

    const script = "return fail(-1)";
    const result = try z.execTraceback(script);
    defer z.freeTraceBackResult(result);

    switch (result) {
        .Ok => {},
        .Runtime => |msg| std.debug.print("Lua runtime failed:\n{s}\n", .{msg}),
        .Syntax => |msg| std.debug.print("Lua syntax failed:\n{s}\n", .{msg}),
        .OutOfMemory => |msg| std.debug.print("Lua out of memory:\n{s}\n", .{msg}),
        .MessageHandler => |msg| std.debug.print("Lua message handler failed:\n{s}\n", .{msg}),
        .File => |msg| std.debug.print("Lua file error:\n{s}\n", .{msg}),
        .Unknown => |msg| std.debug.print("Lua unknown error:\n{s}\n", .{msg}),
    }
}

fn fail(value: i32) !Result(i32) {
    if (value < 0) return Error.InvalidValue;
    return Result(i32).ok(value + 1);
}
