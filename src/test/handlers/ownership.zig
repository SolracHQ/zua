const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");

fn increment(x: i32) i32 { return x + 1; }

test "Any.Function.create and ownership lifecycle" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var handle = zua.Handlers.Any.Function.create(test_env.state, increment);
    const owned = handle.takeOwnership();
    defer owned.release();
    const result = try owned.call(&test_env.ctx, .{5}, i32);
    try testing.expectEqual(6, result);
}

test "Typed.Fn.create and ownership lifecycle" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var typed = zua.Handlers.Typed.Fn(.{i32}, i32).create(&test_env.ctx, increment);
    const owned = typed.takeOwnership();
    defer owned.release();
    const result = try owned.call(&test_env.ctx, .{5});
    try testing.expectEqual(6, result);
}
