const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

const Handle = opaque {
    pub const ZUA_SHAPE = Shape.Ptr(Handle, .{ .name = "Handle" });
};

fn makeHandle(ctx: *zua.Context) !*Handle {
    const memory = try ctx.arena().alloc(u8, 1);
    return @ptrCast(@alignCast(memory.ptr));
}

fn inspectHandle(_: *Handle) void {}

test "Shape.Ptr opaque handle passed as light userdata" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .make = Shape.Fn(makeHandle, .{}),
        .inspect = Shape.Fn(inspectHandle, .{}),
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\local h = make()
        \\assert(type(h) == "userdata")
        \\inspect(h)
    } });
}
