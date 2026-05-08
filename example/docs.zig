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

const Color = enum(u8) { red, green, blue };
const Mode = enum { idle, running, stopped };

const ConcreteOs = enum {
    windows,
    linux,
    macos,
    bsd,
};

const OsFamily = enum {
    unix_like,
    bsd_based,
};

const Os = union(enum) {
    Concrete: ConcreteOs,
    Family: OsFamily,

    pub const ZUA_META = zua.Meta.Table(Os, .{}, .{
        .name = "Os",
        .description = "Operating system selector. Accepted as strings like \"linux\", \"macos\", \"unix-like\", or \"bsd-based\".",
    }).withDecode(decode).withDocs(osDocs);

    fn decode(ctx: *zua.Context, prim: zua.Mapper.Decoder.Primitive) !?Os {
        return switch (prim) {
            .string => |s| {
                if (std.mem.eql(u8, s, "windows")) return .{ .Concrete = .windows };
                if (std.mem.eql(u8, s, "linux")) return .{ .Concrete = .linux };
                if (std.mem.eql(u8, s, "macos")) return .{ .Concrete = .macos };
                if (std.mem.eql(u8, s, "bsd")) return .{ .Concrete = .bsd };
                if (std.mem.eql(u8, s, "unix-like")) return .{ .Family = .unix_like };
                if (std.mem.eql(u8, s, "bsd-based")) return .{ .Family = .bsd_based };
                return ctx.failTyped(?Os, "unknown os: {s}", .{s});
            },
            else => return null,
        };
    }

    fn osDocs(self: *zua.Docs) !void {
        var alias = zua.Docs.Alias{
            .name = try self.arena.allocator().dupe(u8, "Os"),
            .description = try self.arena.allocator().dupe(u8, "Operating system selector."),
            .values = .empty,
        };
        for ([_][]const u8{ "windows", "linux", "macos", "bsd", "unix-like", "bsd-based" }) |name| {
            try alias.values.append(self.arena.allocator(), .{
                .type = try std.fmt.allocPrint(self.arena.allocator(), "'{s}'", .{name}),
                .description = "",
            });
        }
        try self.aliases.append(self.arena.allocator(), alias);
    }
};

fn getStatus() []const u8 {
    return "active";
}

const get_status = zua.Native.new(getStatus, .{}, .{
    .name = "status",
    .description = "Get the current status string.",
});

const Logger = struct {
    pub const ZUA_META = zua.Meta.Table(Logger, .{}, .{
        .name = "Logger",
        .description = "Logging utility with a shared status function.",
    });
    status: @TypeOf(get_status) = get_status,
};

const Analytics = struct {
    pub const ZUA_META = zua.Meta.Table(Analytics, .{}, .{
        .name = "Analytics",
        .description = "Analytics tracker with a shared status function.",
    });
    status: @TypeOf(get_status) = get_status,
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

    try generator.add(Os);
    try generator.add(Priority);
    try generator.add(Color);
    try generator.add(Mode);
    try generator.add(make_vector);
    try generator.add(new_counter);
    try generator.add(maybe_increment);
    try generator.add(sum_all);
    try generator.add(Vector2);
    try generator.add(Logger);
    try generator.add(Analytics);
    const stubs = try generator.generate();
    std.debug.print("{s}", .{stubs});
}
