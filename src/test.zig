const std = @import("std");
const testing = std.testing;
const State = @import("root.zig").State;
const Context = @import("root.zig").Context;
const Executor = @import("root.zig").Executor;
const Handlers = @import("root.zig").Handlers;
const Shape = @import("root.zig").Shape;
const Mapper = @import("root.zig").Mapper;

const Arg = struct {
    pub const ZUA_SHAPE = Shape.Table(@This(), .{}, .{});
    value: i32,
};

fn takeArg(_: *Context, _: Arg) void {}

fn threeArgs(_: *Context, _: i32, _: i32, _: Arg) void {}

test "decode error path shows named 3rd arg" {
    const state = try State.init(testing.allocator, testing.io);
    defer state.deinit();
    var ctx = Context.init(state);
    defer ctx.deinit();

    try state.addGlobals(&ctx, .{
        .third = Shape.Fn(threeArgs, .{ .args = &.{
            .{ .name = "a" },
            .{ .name = "b" },
            .{ .name = "c" },
        } }),
    });

    var executor = Executor{};
    try executor.execute(&ctx, .{ .code = .{ .string =
        \\local ok, err = pcall(third, 1, 2, {value = "bad"})
        \\assert(type(err) == "string")
        \\assert(err:find("c.value") ~= nil, "expected 'c.value', found: " .. tostring(err))
        \\assert(err:find("arg2") == nil, "default 'arg2' should be replaced by named arg 'c'")
    } });
}

test "decode error path shows arg2 for unnamed 3rd arg" {
    const state = try State.init(testing.allocator, testing.io);
    defer state.deinit();
    var ctx = Context.init(state);
    defer ctx.deinit();

    try state.addGlobals(&ctx, .{
        .third = Shape.Fn(threeArgs, .{}),
    });

    var executor = Executor{};
    try executor.execute(&ctx, .{ .code = .{ .string =
        \\local ok, err = pcall(third, 1, 2, {value = "bad"})
        \\assert(type(err) == "string")
        \\assert(err:find("arg2") ~= nil, "expected 'arg2', found: " .. tostring(err))
    } });
}

test "decode error path shows nested field" {
    const state = try State.init(testing.allocator, testing.io);
    defer state.deinit();
    var ctx = Context.init(state);
    defer ctx.deinit();

    try state.addGlobals(&ctx, .{
        .take = Shape.Fn(takeArg, .{ .args = &.{.{ .name = "cfg" }} }),
    });

    var executor = Executor{};
    try executor.execute(&ctx, .{ .code = .{ .string =
        \\local ok, err = pcall(take, {value = "bad"})
        \\assert(type(err) == "string")
        \\assert(err:find("cfg") ~= nil, "expected error to contain arg name")
        \\assert(err:find("value") ~= nil, "expected error to contain field name")
    } });
}

test "decode error on Fn return shows field without arg prefix" {
    const state = try State.init(testing.allocator, testing.io);
    defer state.deinit();
    var ctx = Context.init(state);
    defer ctx.deinit();

    var executor = Executor{};
    try executor.execute(&ctx, .{ .code = .{ .string =
        \\function make_bad() return {value = "bad"} end
    } });

    const FnT = Handlers.Typed.Fn(.{}, Arg);
    const g = state.globals();
    const lua_fn = try g.get(&ctx, "make_bad", Handlers.Any.Function);
    const typed = FnT.from(lua_fn);

    const result = typed.call(&ctx, .{});
    try testing.expectError(error.Failed, result);
    try testing.expect(std.mem.indexOf(u8, ctx.err orelse "", ".value") != null);
    // No "arg" prefix should appear since this is a return value, not an argument
    try testing.expect(std.mem.indexOf(u8, ctx.err orelse "", "arg") == null);
}
