const std = @import("std");
const testing = std.testing;
const helpers = @import("../../helpers.zig");
const zua = @import("../../../root.zig");
const Executor = zua.Executor;

fn increment(x: i32) i32 { return x + 1; }

test "Typed.Fn.from wraps an Any.Function handle" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\function double(x) return x * 2 end
    } });

    const globals = test_env.state.globals();
    const raw = try globals.get(&test_env.ctx, "double", zua.Handlers.Any.Function);
    const typed = zua.Handlers.Typed.Fn(.{i32}, i32).from(raw);

    const result = try typed.call(&test_env.ctx, .{21});
    try testing.expectEqual(@as(i32, 42), result);
}

test "Typed.Fn.owned creates second registry reference" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var typed = zua.Handlers.Typed.Fn(.{i32}, i32).create(&test_env.ctx, increment);
    const first = typed.takeOwnership();
    defer first.release();

    const second = first.owned();
    defer second.release();

    try testing.expectEqual(@as(i32, 6), try first.call(&test_env.ctx, .{5}));
    try testing.expectEqual(@as(i32, 6), try second.call(&test_env.ctx, .{5}));
}
