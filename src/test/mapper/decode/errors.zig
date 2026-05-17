const std = @import("std");
const testing = std.testing;
const helpers = @import("../../helpers.zig");
const zua = @import("../../../root.zig");
const Executor = zua.Executor;
const Handlers = zua.Handlers;
const Shape = zua.Shape;

const ConfigArg = struct {
    pub const ZUA_SHAPE = Shape.Table(@This(), .{}, .{});
    value: i32,
};

fn takeConfigArg(_: *zua.Context, _: ConfigArg) void {}

fn threeArgs(_: *zua.Context, _: i32, _: i32, _: ConfigArg) void {}

test "decode error path shows named 3rd arg" {
    var test_context = try helpers.setup();
    defer test_context.deinit();

    try test_context.state.addGlobals(&test_context.ctx, .{
        .third = Shape.Fn(threeArgs, .{ .args = &.{
            .{ .name = "a" },
            .{ .name = "b" },
            .{ .name = "c" },
        } }),
    });

    var executor = Executor{};
    try executor.execute(&test_context.ctx, .{ .code = .{ .string =
        \\local ok, err = pcall(third, 1, 2, {value = "bad"})
        \\assert(type(err) == "string")
        \\assert(err:find("c.value") ~= nil, "expected 'c.value', found: " .. tostring(err))
        \\assert(err:find("arg2") == nil, "default 'arg2' should be replaced by named arg 'c'")
    } });
}

test "decode error path shows arg2 for unnamed 3rd arg" {
    var test_context = try helpers.setup();
    defer test_context.deinit();

    try test_context.state.addGlobals(&test_context.ctx, .{
        .third = Shape.Fn(threeArgs, .{}),
    });

    var executor = Executor{};
    try executor.execute(&test_context.ctx, .{ .code = .{ .string =
        \\local ok, err = pcall(third, 1, 2, {value = "bad"})
        \\assert(type(err) == "string")
        \\assert(err:find("arg2") ~= nil, "expected 'arg2', found: " .. tostring(err))
    } });
}

test "decode error path shows nested field" {
    var test_context = try helpers.setup();
    defer test_context.deinit();

    try test_context.state.addGlobals(&test_context.ctx, .{
        .take = Shape.Fn(takeConfigArg, .{ .args = &.{.{ .name = "cfg" }} }),
    });

    var executor = Executor{};
    try executor.execute(&test_context.ctx, .{ .code = .{ .string =
        \\local ok, err = pcall(take, {value = "bad"})
        \\assert(type(err) == "string")
        \\assert(err:find("cfg") ~= nil, "expected error to contain arg name")
        \\assert(err:find("value") ~= nil, "expected error to contain field name")
    } });
}

test "decode error on Fn return shows field without arg prefix" {
    var test_context = try helpers.setup();
    defer test_context.deinit();

    var executor = Executor{};
    try executor.execute(&test_context.ctx, .{ .code = .{ .string =
        \\function make_bad() return {value = "bad"} end
    } });

    const FunctionType = Handlers.Typed.Fn(.{}, ConfigArg);
    const globals_table = test_context.state.globals();
    const lua_function = try globals_table.get(&test_context.ctx, "make_bad", Handlers.Any.Function);
    const typed_function = FunctionType.from(lua_function);

    const result = typed_function.call(&test_context.ctx, .{});
    try testing.expectError(error.Failed, result);
    try testing.expect(std.mem.indexOf(u8, test_context.ctx.err orelse "", ".value") != null);
    try testing.expect(std.mem.indexOf(u8, test_context.ctx.err orelse "", "arg") == null);
}
