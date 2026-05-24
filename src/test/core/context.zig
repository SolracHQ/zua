const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

fn greet(ctx: *zua.Context, name: []const u8) []const u8 {
    return std.fmt.allocPrint(ctx.arena(), "Hello, {s}!", .{name}) catch "nomem";
}

test "fn using ctx.arena() works from Lua" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .greet = Shape.Fn(greet, .{}),
    });
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, []const u8, .{ .code = .{ .string =
        \\return greet("Zig")
    } });
    try testing.expectEqualStrings("Hello, Zig!", result);
}

test "ctx.heap() allocates persistent memory" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    const memory = try test_env.ctx.heap().alloc(u8, 64);
    defer test_env.ctx.heap().free(memory);
    try testing.expect(memory.len == 64);
}

test "ctx.fail returns error.Failed and sets err" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try testing.expectError(error.Failed, test_env.ctx.fail("something broke"));
    try testing.expectEqualStrings("something broke", test_env.ctx.err.?);
}

test "ctx.failTyped returns error.Failed as typed result" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try testing.expectError(error.Failed, test_env.ctx.failTyped(i32, "bad value"));
    try testing.expectEqualStrings("bad value", test_env.ctx.err.?);
}

test "ctx.failWithFmt formats message" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try testing.expectError(error.Failed, test_env.ctx.failWithFmt("error code {d}", .{404}));
    try testing.expectEqualStrings("error code 404", test_env.ctx.err.?);
}

test "ctx.failWithFmtTyped formats typed message" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try testing.expectError(error.Failed, test_env.ctx.failWithFmtTyped([]const u8, "invalid {s}", .{"input"}));
    try testing.expectEqualStrings("invalid input", test_env.ctx.err.?);
}
