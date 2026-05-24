const std = @import("std");
const testing = std.testing;
const helpers = @import("../helpers.zig");
const zua = @import("../../root.zig");
const Shape = zua.Shape;
const Executor = zua.Executor;

const Color = enum {
    red,
    green,
    blue,
    pub const ZUA_SHAPE = Shape.StrAlias(Color, .{}, .{});
};

fn returnColor() Color { return .green; }

fn takeColor(_: *zua.Context, c: Color) []const u8 { return @tagName(c); }

test "StrAlias round-trips through Lua as string" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .get_color = Shape.Fn(returnColor, .{}),
        .check_color = Shape.Fn(takeColor, .{}),
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\local c = get_color()
        \\assert(c == "green")
        \\assert(check_color("blue") == "blue")
    } });
}

const Priority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,
    pub const ZUA_SHAPE = Shape.Alias(Priority, .{}, .{})
        .withEncode([]const u8, encodeStr)
        .withDecode(decodeStrOrInt);

    fn encodeStr(_: *zua.Context, p: Priority) !?[]const u8 {
        return @tagName(p);
    }

    fn decodeStrOrInt(ctx: *zua.Context, primitive: zua.Mapper.Primitive) !?Priority {
        switch (primitive) {
            .string => |s| {
                inline for (std.meta.fields(Priority)) |field| {
                    if (std.mem.eql(u8, s, field.name)) return @field(Priority, field.name);
                }
                return ctx.failTyped(?Priority, "unknown priority name");
            },
            .integer => |n| {
                const byte = std.math.cast(u8, n) orelse
                    return ctx.failTyped(?Priority, "priority out of range");
                if (byte > @intFromEnum(Priority.high))
                    return ctx.failTyped(?Priority, "invalid priority");
                return @enumFromInt(byte);
            },
            else => return ctx.failTyped(?Priority, "expected string or integer"),
        }
    }
};

fn returnPriority() Priority { return .normal; }

fn describePriority(ctx: *zua.Context, p: Priority) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena(), "priority={s} ({})", .{ @tagName(p), @intFromEnum(p) }) catch
        try ctx.failTyped([]const u8, "out of memory");
}

test "Alias with custom encode/decode hooks" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .get_priority = Shape.Fn(returnPriority, .{}),
        .describe = Shape.Fn(describePriority, .{}),
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\local p = get_priority()
        \\assert(p == "normal")
        \\assert(describe("low") == "priority=low (0)")
        \\assert(describe(1) == "priority=normal (1)")
        \\assert(describe("high") == "priority=high (2)")
    } });
}

const Condition = union(enum) {
    eq: f64,
    in_range: struct { min: f64, max: f64 },

    pub const ZUA_SHAPE = Shape.TypedAlias(Condition, .{}, .{});
};

fn makeEqCondition(value: f64) Condition { return .{ .eq = value }; }

fn describeCondition(ctx: *zua.Context, cond: Condition) ![]const u8 {
    return switch (cond) {
        .eq => |v| std.fmt.allocPrint(ctx.arena(), "eq {d}", .{v}) catch "nomem",
        .in_range => |r| std.fmt.allocPrint(ctx.arena(), "in_range {{{d},{d}}}", .{ r.min, r.max }) catch "nomem",
    };
}

test "TypedAlias encodes and decodes tagged unions" {
    var test_env = try helpers.setup();
    defer test_env.deinit();
    try test_env.state.addGlobals(&test_env.ctx, .{
        .make_eq = Shape.Fn(makeEqCondition, .{}),
        .describe = Shape.Fn(describeCondition, .{}),
    });
    var executor = Executor{};
    try executor.execute(&test_env.ctx, .{ .code = .{ .string =
        \\local c = make_eq(8.3)
        \\assert(describe(c) == "eq 8.3")
        \\assert(describe({eq = 8.3}) == "eq 8.3")
    } });
}
