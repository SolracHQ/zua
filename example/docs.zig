const std = @import("std");
const zua = @import("zua");
const ArgInfo = zua.Native.ArgInfo;

const Vector2 = struct {
    pub const ZUA_META = zua.Meta.Table(Vector2, .{
        .scale = zua.Native.new(scale, .{}).withDescriptions(.{
            ArgInfo{ .name = "factor", .description = "Scalar multiplier applied to both coordinates." },
        }),
    })
        .withDescription("Simple table-backed 2D vector.")
        .withAttribDescriptions(.{
            .x = "Horizontal coordinate.",
            .y = "Vertical coordinate.",
        })
        .withName("Vector2");

    x: f64,
    y: f64,

    fn scale(self: Vector2, factor: f64) Vector2 {
        return .{ .x = self.x * factor, .y = self.y * factor };
    }
};

const Counter = struct {
    pub const ZUA_META = zua.Meta.Object(Counter, .{
        .value = getValue,
        .increment = zua.Native.new(increment, .{}).withDescriptions(.{
            ArgInfo{ .name = "amount", .description = "Amount added to the counter." },
        }).withDescription("Increment the counter by a specified amount."),
    }).withDescription("Opaque counter object with identity.")
        .withName("Counter");

    count: i32 = 0,

    fn getValue(self: *const Counter) i32 {
        return self.count;
    }

    fn increment(self: *Counter, amount: i32) void {
        self.count += amount;
    }
};

const Range = struct {
    pub const ZUA_META = zua.Meta.Table(Range, .{})
        .withDescription("Range condition with minimum and maximum bounds.")
        .withAttribDescriptions(.{
            .min = "Minimum bound of the range.",
            .max = "Maximum bound of the range.",
        })
        .withName("Range");
    min: i32,
    max: i32,
};

const Condition = union(enum) {
    eq: i32,
    in_range: Range,

    pub const ZUA_META = zua.Meta.Table(@This(), .{})
        .withDescription("Tagged union selector accepted by scan-style APIs.")
        .withName("Condition");
};

const Priority = enum(u8) {
    low,
    normal,
    high,

    pub const ZUA_META = zua.Meta.strEnum(@This(), .{})
        .withDescription("String-backed priority enum.")
        .withName("Priority");
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

    const make_vector = zua.Native.new(makeVector, .{}).withDescriptions(.{
        ArgInfo{ .name = "x", .description = "Initial horizontal coordinate." },
        ArgInfo{ .name = "y", .description = "Initial vertical coordinate." },
    }).withName("make_vector").withDescription("Construct a new Vector2 value.");

    const new_counter = zua.Native.new(newCounter, .{}).withName("new_counter").withDescription("Create a new Counter instance.");

    const maybe_increment = zua.Native.new(maybeIncrement, .{}).withDescriptions(.{
        ArgInfo{ .name = "value", .description = "Optional integer to increment." },
    }).withName("maybe_increment").withDescription("Increment a number when one is provided.");

    const sum_all = zua.Native.new(sumAll, .{}).withDescriptions(.{
        ArgInfo{ .name = "condition", .description = "Selector for which integers to sum." },
        ArgInfo{ .name = "...", .description = "Additional integer values." },
    }).withName("sum_all").withDescription("Sum all integer varargs.");

    const module = .{ .make_vector = make_vector, .new_counter = new_counter, .maybe_increment = maybe_increment, .sum_all = sum_all };

    const stubs = try zua.Docs.generateModule(init.gpa, module, "zua");
    std.debug.print("{s}", .{stubs});
}
