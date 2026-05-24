const std = @import("std");
const testing = std.testing;
const helpers = @import("../../helpers.zig");
const zua = @import("../../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

fn inspectTable(ctx: *zua.Context, table_handle: zua.Handlers.Any.Table) ![]const u8 {
    const name = try table_handle.get(ctx, "name", []const u8);
    const first = try table_handle.get(ctx, 1, i32);
    return std.fmt.allocPrint(ctx.arena(), "{s} first is {d}", .{ name, first }) catch "nomem";
}

test "Any.Table handles both string and integer keys" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .inspect = Shape.Fn(inspectTable, .{}),
    });
    var executor = Executor{};
    const result = try executor.eval(&test_env.ctx, []const u8, .{ .code = .{ .string =
        \\local t = {42, name = "table"}
        \\return inspect(t)
    } });
    try testing.expectEqualStrings("table first is 42", result);
}

test "Table.create and set then get back" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var table = zua.Handlers.Any.Table.create(test_env.state, 0, 2);
    defer table.release();

    try table.set(&test_env.ctx, "name", "test");
    try table.set(&test_env.ctx, "value", 99);

    const name = try table.get(&test_env.ctx, "name", []const u8);
    try testing.expectEqualStrings("test", name);
    const value = try table.get(&test_env.ctx, "value", i32);
    try testing.expectEqual(@as(i32, 99), value);
}

test "Table.create with integer keys" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var table = zua.Handlers.Any.Table.create(test_env.state, 3, 0);
    defer table.release();

    try table.set(&test_env.ctx, 1, 10);
    try table.set(&test_env.ctx, 2, 20);
    try table.set(&test_env.ctx, 3, 30);

    try testing.expectEqual(@as(i32, 10), try table.get(&test_env.ctx, 1, i32));
    try testing.expectEqual(@as(i32, 20), try table.get(&test_env.ctx, 2, i32));
    try testing.expectEqual(@as(i32, 30), try table.get(&test_env.ctx, 3, i32));
}

test "Table.takeOwnership and owned lifecycle" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var table = zua.Handlers.Any.Table.create(test_env.state, 0, 0);
    try table.set(&test_env.ctx, "key", 7);

    const owned = table.takeOwnership();
    defer owned.release();

    const back = try owned.get(&test_env.ctx, "key", i32);
    try testing.expectEqual(@as(i32, 7), back);
}

test "Table.from converts Zig struct to Lua table" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    const Point = struct { x: i32, y: i32 };
    var table = try zua.Handlers.Any.Table.from(test_env.state, &test_env.ctx, Point{ .x = 10, .y = 20 });
    defer table.release();

    const x = try table.get(&test_env.ctx, "x", i32);
    const y = try table.get(&test_env.ctx, "y", i32);
    try testing.expectEqual(@as(i32, 10), x);
    try testing.expectEqual(@as(i32, 20), y);
}

test "Table.has on table with set" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    var table = zua.Handlers.Any.Table.create(test_env.state, 0, 2);
    try table.set(&test_env.ctx, "a", 1);
    try testing.expect(table.has("a"));
    try testing.expect(!table.has("b"));
}
