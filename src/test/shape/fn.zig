const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

const Greeter = struct {
    pub const ZUA_SHAPE = Shape.Fn(greet, .{});
    fn greet(ctx: *zua.Context, name: []const u8) []const u8 {
        return std.fmt.allocPrint(ctx.arena(), "Hello, {s}!", .{name}) catch "nomem";
    }
};

test "struct with ZUA_SHAPE = Shape.Fn pushed as function" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .greet = Greeter{},
    });
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, []const u8, .{ .code = .{ .string =
        \\return greet("World")
    } });
    try testing.expectEqualStrings("Hello, World!", result);
}

fn multiReturnExample() struct { i32, f64 } {
    return .{ 42, 3.14 };
}

test "function returning multiple values through Lua" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .multi = multiReturnExample,
    });
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, .{i32, f64}, .{ .code = .{ .string =
        \\return multi()
    } });
    try testing.expectEqual(42, result[0]);
    try testing.expectEqual(@as(f64, 3.14), result[1]);
}

test "Lua native multiple return parsed as tuple" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, .{bool, []const u8, i32}, .{ .code = .{ .string =
        \\return true, "hello", 99
    } });
    try testing.expectEqual(true, result[0]);
    try testing.expectEqualStrings("hello", result[1]);
    try testing.expectEqual(99, result[2]);
}
