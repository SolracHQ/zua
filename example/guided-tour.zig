//! Guided tour example for zua.
//!
//! This example demonstrates the library's core surface:
//! - exporting Zig functions and values into Lua
//! - table-backed structs with method metadata
//! - object-backed userdata with live mutation and `__tostring`
//! - callbacks from Lua into Zig and back
//! - array processing and multi-value returns
//!

const std = @import("std");
const zua = @import("zua");

// Simple functions for demonstration
fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn multiply(a: f64, b: f64) f64 {
    return a * b;
}

// A custom type with methods and table-backed semantics
const Vector2 = struct {
    pub const ZUA_META = zua.Meta.Table(Vector2, .{
        .length = length,
        .normalize = normalize,
        .translate = translate,
    });

    x: f64,
    y: f64,

    pub fn length(self: Vector2) f64 {
        return std.math.sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn normalize(self: Vector2) Vector2 {
        const len = std.math.sqrt(self.x * self.x + self.y * self.y);
        if (len == 0) return Vector2{ .x = 0, .y = 0 };
        return Vector2{ .x = self.x / len, .y = self.y / len };
    }

    pub fn translate(ctx: *zua.Context, self: zua.TableView(Vector2), dx: f64, dy: f64) !void {
        self.ref.x += dx;
        self.ref.y += dy;
        try self.sync(ctx);
    }
};

// A stateful object backed by userdata and exposed via methods
const Counter = struct {
    pub const ZUA_META = zua.Meta.Object(Counter, .{
        .value = getValue,
        .increment = increment,
        .__tostring = toString,
    });

    count: i32,

    pub fn getValue(self: *Counter) i32 {
        return self.count;
    }

    pub fn increment(self: *Counter, amount: i32) void {
        self.count += amount;
    }

    pub fn toString(ctx: *zua.Context, self: *Counter) []const u8 {
        const arena = ctx.arena();
        const msg = std.fmt.allocPrint(arena, "Counter({d})", .{self.count}) catch {
            ctx.err = "out of memory";
            return "";
        };
        return msg;
    }
};

// Functions to create our types
fn makeCounter() !Counter {
    return Counter{ .count = 0 };
}

fn makeVector(x: f64, y: f64) Vector2 {
    return Vector2{ .x = x, .y = y };
}

fn mapWithCallback(ctx: *zua.Context, callback: zua.Function, numbers: []const i32) !void {
    for (numbers) |value| {
        const mapped = try callback.call(ctx, .{value}, i32);
        std.debug.print("  Mapped: {d}\n", .{mapped});
    }
}

fn filterAndSum(ctx: *zua.Context, predicate: zua.Function, numbers: []const i32) !i32 {
    var sum: i32 = 0;
    for (numbers) |value| {
        const is_match = try predicate.call(ctx, .{value}, bool);
        if (is_match) sum += value;
    }
    return sum;
}

fn multiReturnExample() struct { i32, f64 } {
    return .{ 42, 3.14 };
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.State.init(init.gpa, init.io);
    defer z.deinit();
    var executor = zua.Executor{};
    var ctx = zua.Context.init(z);
    defer ctx.deinit();

    const globals = z.globals();
    defer globals.release();

    // Register functions
    try globals.set(&ctx, "add", add);
    try globals.set(&ctx, "multiply", multiply);
    try globals.set(&ctx, "Counter", makeCounter);
    try globals.set(&ctx, "Vector", zua.Native.new(makeVector, .{ .parse_err_fmt = "Vector expects (number, number): {s}" }));
    try globals.set(&ctx, "map_with_callback", zua.Native.new(mapWithCallback, .{ .parse_err_fmt = "map_with_callback expects (function, array): {s}" }));
    try globals.set(&ctx, "filter_and_sum", zua.Native.new(filterAndSum, .{ .parse_err_fmt = "filter_and_sum expects (function, array): {s}" }));
    try globals.set(&ctx, "multi_return_example", multiReturnExample);

    const code =
        \\-- Basic function calls
        \\print("Basic Functions:")
        \\print("add(5, 3) =", add(5, 3))
        \\print("multiply(4.5, 2) =", multiply(4.5, 2))
        \\
        \\-- Data structures
        \\print("\nData Structures:")
        \\local point = {x = 3, y = 4}
        \\print("Table point:", point.x, point.y)
        \\
        \\-- Vector type with methods
        \\print("\nCustom Type (Vector):")
        \\local v = Vector(3, 4)
        \\print("Vector:", v.x, v.y)
        \\print("Vector length:", v:length())
        \\local v_norm = v:normalize()
        \\print("Normalized vector:", v_norm.x, v_norm.y)
        \\v:translate(2, 1)
        \\print("Translated vector:", v.x, v.y)
        \\
        \\-- Stateful object
        \\print("\nStateful Object (Counter):")
        \\local c = Counter()
        \\print("Initial counter:", c:value())
        \\c:increment(5)
        \\print("After increment(5):", c:value())
        \\c:increment(3)
        \\print("After increment(3):", c:value())
        \\print("Counter as string:", tostring(c))
        \\
        \\-- Processing arrays
        \\print("\nProcessing Arrays:")
        \\local numbers = {5, 10, 15, 20}
        \\print("Array: {5, 10, 15, 20}")
        \\
        \\-- Map: process each element with callback
        \\local double_callback = function(x) return x * 2 end
        \\map_with_callback(double_callback, numbers)
        \\
        \\-- Filter and sum: use callback to filter even numbers
        \\local is_even = function(x) return x % 2 == 0 end
        \\local sum_evens = filter_and_sum(is_even, numbers)
        \\print("Sum of even numbers:", sum_evens)
        \\
        \\-- Multi-value return example
        \\print("\nMulti-value Return:")
        \\local a, b = multi_return_example()
        \\print("Values returned:", a, b)
        \\
        \\print("\nAll features demonstrated!")
    ;

    executor.execute(&ctx, .{ .code = .{ .string = code } }) catch |err| {
        std.debug.print("Lua error: {s}\n", .{ctx.err orelse "unknown error"});
        return err;
    };
}
