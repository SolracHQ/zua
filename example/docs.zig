const std = @import("std");
const zua = @import("zua");

const Vector2 = struct {
    pub const ZUA_META = zua.Meta.Table(Vector2, .{
        .scale = zua.Native.new(scale, .{}, .{
            .args = &.{
                .{ .name = "factor", .description = "Scalar multiplier applied to both coordinates." },
            },
        }),
    }, .{
        .name = "Vector2",
        .description = "Simple table-backed 2D vector.",
        .field_descriptions = .{
            .x = "Horizontal coordinate.",
            .y = "Vertical coordinate.",
        },
    });

    x: f64,
    y: f64,

    fn scale(self: Vector2, factor: f64) Vector2 {
        return .{ .x = self.x * factor, .y = self.y * factor };
    }
};

const Counter = struct {
    pub const ZUA_META = zua.Meta.Object(Counter, .{
        .value = getValue,
        .increment = zua.Native.new(increment, .{}, .{
            .description = "Increment the counter by a specified amount.",
            .args = &.{
                .{ .name = "amount", .description = "Amount added to the counter." },
            },
        }),
    }, .{
        .name = "Counter",
        .description = "Opaque counter object with identity.",
    });

    count: i32 = 0,

    fn getValue(self: *const Counter) i32 {
        return self.count;
    }

    fn increment(self: *Counter, amount: i32) void {
        self.count += amount;
    }
};

const Condition = union(enum) {
    eq: i32,
    in_range: struct { min: i32, max: i32 },

    pub const ZUA_META = zua.Meta.Table(Condition, .{}, .{
        .name = "Condition",
        .description = "Tagged union selector accepted by scan-style APIs.",
        .variants = .{
            .eq = .{
                .description = "Exact match against a single value.",
            },
            .in_range = .{
                .name = "ConditionRange",
                .description = "Match values within a range.",
                .field_descriptions = .{
                    .min = "Minimum bound of the range.",
                    .max = "Maximum bound of the range.",
                },
            },
        },
    });
};

const Priority = enum(u8) {
    low,
    normal,
    high,

    pub const ZUA_META = zua.Meta.strEnum(Priority, .{}, .{
        .name = "Priority",
        .description = "String-backed priority enum.",
    });
};

fn makeVector(x: f64, y: f64) Vector2 {
    return .{ .x = x, .y = y };
}

fn newCounter() Counter {
    return .{};
}

fn maybeIncrement(value: ?i32) ?i32 {
    return if (value) |n| n + 1 else null;
}

fn sumAll(_: *zua.Context, condition: Condition, args: zua.VarArgs) i64 {
    var total: i64 = 0;
    for (args.args) |prim| switch (prim) {
        .integer => |n| switch (condition) {
            .eq => |target| {
                if (n == target) total += n;
            },
            .in_range => |range| {
                if (n >= range.min and n <= range.max) total += n;
            },
        },
        else => {},
    };
    return total;
}

pub fn main(init: std.process.Init) !void {
    var generator = zua.Docs.init(init.gpa);
    defer generator.deinit();

    const make_vector = zua.Native.new(makeVector, .{}, .{
        .name = "make_vector",
        .description = "Construct a new Vector2 value.",
        .args = &.{
            .{ .name = "x", .description = "Initial horizontal coordinate." },
            .{ .name = "y", .description = "Initial vertical coordinate." },
        },
    });

    const new_counter = zua.Native.new(newCounter, .{}, .{
        .name = "new_counter",
        .description = "Create a new Counter instance.",
    });

    const maybe_increment = zua.Native.new(maybeIncrement, .{}, .{
        .name = "maybe_increment",
        .description = "Increment a number when one is provided.",
        .args = &.{
            .{ .name = "value", .description = "Optional integer to increment." },
        },
    });

    const sum_all = zua.Native.new(sumAll, .{}, .{
        .name = "sum_all",
        .description = "Sum all integer varargs.",
        .args = &.{
            .{ .name = "condition", .description = "Selector for which integers to sum." },
            .{ .name = "...", .description = "Additional integer values." },
        },
    });

    const module = .{
        .make_vector = make_vector,
        .new_counter = new_counter,
        .maybe_increment = maybe_increment,
        .sum_all = sum_all,
        .testVector2 = Vector2{ .x = 1, .y = 2 },
    };

    const stubs = try zua.Docs.generateModule(init.gpa, module, "zua");
    defer init.gpa.free(stubs);
    std.debug.print("{s}", .{stubs});
}
