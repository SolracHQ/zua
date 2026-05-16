const std = @import("std");
const zua = @import("zua");

const Vector2 = struct {
    pub const ZUA_SHAPE = zua.Shape.Table(Vector2, .{
        .scale = zua.Shape.Fn(scale, .{
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
    pub const ZUA_SHAPE = zua.Shape.Object(Counter, .{
        .value = getValue,
        .increment = zua.Shape.Fn(increment, .{
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

    pub const ZUA_SHAPE = zua.Shape.TypedAlias(Condition, .{}, .{
        .name = "Condition",
        .description = "Tagged union selector accepted by scan-style APIs.",
        .variant_descriptions = .{
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

    pub const ZUA_SHAPE = zua.Shape.StrAlias(Priority, .{}, .{
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

    pub const ZUA_SHAPE = zua.Shape.TypedAlias(Os, .{}, .{
        .name = "Os",
        .description = "Operating system selector. Accepted as strings like \"linux\", \"macos\", \"unix-like\", or \"bsd-based\".",
    }).withDecode(decode).withDocs(osDocs);

    fn decode(ctx: *zua.Context, prim: zua.Mapper.Primitive) !?Os {
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

    fn osDocs(self: *zua.Docs.Generator) !void {
        var alias = zua.Docs.Entry.Alias{
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

const get_status = zua.Shape.Fn(getStatus, .{
    .description = "Get the current status string.",
});

const Logger = struct {
    pub const ZUA_SHAPE = zua.Shape.Table(Logger, .{}, .{
        .name = "Logger",
        .description = "Logging utility with a shared status function.",
    });
    status: @TypeOf(get_status) = get_status,
};

const Analytics = struct {
    pub const ZUA_SHAPE = zua.Shape.Table(Analytics, .{}, .{
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

fn sumAll(condition: Condition, args: zua.Mapper.VarArgs) i64 {
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

const CounterClosure = struct {
    pub const ZUA_SHAPE = zua.Shape.Closure(@This(), tick, null, .{
        .description = "Creates a counter that starts at 0 and steps by delta on each call.",
        .args = &.{
            .{ .name = "delta", .description = "Amount added to the counter." },
        },
    });
    count: i32,
    fn tick(up: *CounterClosure, delta: i32) i32 {
        up.count += delta;
        return up.count;
    }
};

pub fn main(init: std.process.Init) !void {
    const stubs = try zua.Docs.generateGlobals(init.gpa, .{
        .Os = Os,
        .Priority = Priority,
        .Color = Color,
        .Mode = Mode,
        .Vector2 = Vector2,
        .Logger = Logger,
        .Analytics = Analytics,
        .make_vector = zua.Shape.Fn(makeVector, .{
            .description = "Construct a new Vector2 value.",
            .args = &.{
                .{ .name = "x", .description = "Initial horizontal coordinate." },
                .{ .name = "y", .description = "Initial vertical coordinate." },
            },
        }),
        .new_counter = zua.Shape.Fn(newCounter, .{
            .description = "Create a new Counter instance.",
        }),
        .maybe_increment = zua.Shape.Fn(maybeIncrement, .{
            .description = "Increment a number when one is provided.",
            .args = &.{
                .{ .name = "value", .description = "Optional integer to increment." },
            },
        }),
        .sum_all = zua.Shape.Fn(sumAll, .{
            .description = "Sum all integer varargs.",
            .args = &.{
                .{ .name = "condition", .description = "Selector for which integers to sum." },
                .{ .name = "...", .description = "Additional integer values." },
            },
        }),
        .make_counter = CounterClosure{ .count = 0 },
    });
    std.debug.print("{s}", .{stubs});
    init.gpa.free(stubs);
}
