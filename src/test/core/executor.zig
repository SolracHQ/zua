const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");
const Executor = zua.Executor;

test "executor execute runs lua code" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\x = 1 + 2
    } });
    const result = try executor.eval(&test_env.ctx, i32, .{ .code = .{ .string = "return x" } });
    try testing.expectEqual(3, result);
}

test "executor eval returns arithmetic result" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, i32, .{ .code = .{ .string = "return (1 + 2) * 3" } });
    try testing.expectEqual(9, result);
}

test "executor eval returns string" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, []const u8, .{ .code = .{ .string = "return 'hello from lua'" } });
    try testing.expectEqualStrings("hello from lua", result);
}

test "executor evalCount returns number of return values" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var executor = Executor{};
    const count = try executor.evalCount(&test_env.ctx, .{ .code = .{ .string = "return 42" } });
    try testing.expectEqual(@as(usize, 1), count);
}

test "executor evalCount with zero returns" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var executor = Executor{};
    const count = try executor.evalCount(&test_env.ctx, .{ .code = .{ .string = "return" } });
    try testing.expectEqual(@as(usize, 0), count);
}

test "executor evalCount with multiple returns" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var executor = Executor{};
    const count = try executor.evalCount(&test_env.ctx, .{ .code = .{ .string = "return 1, 2, 3" } });
    try testing.expectEqual(@as(usize, 3), count);
}
