const std = @import("std");
const zua = @import("zua");
const ArgInfo = zua.Native.ArgInfo;

const Vector2 = struct {
    pub const ZUA_META = zua.Meta.Table(Vector2, .{
        .scale = zua.Native.new(scale, .{}).withDescriptions(.{
            .factor = ArgInfo{ .name = "factor", .description = "Scalar multiplier applied to both coordinates." },
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
            .amount = ArgInfo{ .name = "amount", .description = "Amount added to the counter." },
        }),
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

fn makeVector(x: f64, y: f64) Vector2 {
    return .{ .x = x, .y = y };
}

fn newCounter() Counter {
    return .{};
}

pub fn main(init: std.process.Init) !void {
    var generator = zua.Docs.init(init.gpa);
    defer generator.deinit();

    var make_vector = zua.Native.new(makeVector, .{}).withDescriptions(.{
        .x = ArgInfo{ .name = "x", .description = "Initial horizontal coordinate." },
        .y = ArgInfo{ .name = "y", .description = "Initial vertical coordinate." },
    });
    make_vector.description = "Construct a new Vector2 value.";
    make_vector.name = "make_vector";

    var new_counter = zua.Native.new(newCounter, .{});
    new_counter.description = "Construct a new Counter object.";
    new_counter.name = "new_counter";

    try generator.add(make_vector);
    try generator.add(new_counter);
    try generator.add(Vector2);
    try generator.add(Counter);

    const stubs = try generator.generate();
    std.debug.print("{s}", .{stubs});
}
