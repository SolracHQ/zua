const std = @import("std");
const zua = @import("zua");

const Result = zua.Result;

// Simple functions for demonstration
fn add(a: i32, b: i32) Result(i32) {
    return Result(i32).ok(a + b);
}

fn multiply(a: f64, b: f64) Result(f64) {
    return Result(f64).ok(a * b);
}

// A custom type with methods
const Vector2 = struct {
    pub const ZUA_META = zua.meta.Table(Vector2, .{
        .length = length,
        .normalize = normalize,
    });

    x: f64,
    y: f64,

    pub fn length(self: Vector2) Result(f64) {
        const len = std.math.sqrt(self.x * self.x + self.y * self.y);
        return Result(f64).ok(len);
    }

    pub fn normalize(z: *zua.Zua, self: Vector2) Result(Vector2) {
        _ = z;
        const len = std.math.sqrt(self.x * self.x + self.y * self.y);
        if (len == 0) return Result(Vector2).errStatic("cannot normalize zero vector");
        return Result(Vector2).ok(Vector2{ .x = self.x / len, .y = self.y / len });
    }
};

// A stateful object
const Counter = struct {
    pub const ZUA_META = zua.meta.Object(Counter, .{
        .value = getValue,
        .increment = increment,
        .__tostring = toString,
    });

    count: i32,

    pub fn getValue(self: *Counter) Result(i32) {
        return Result(i32).ok(self.count);
    }

    pub fn increment(self: *Counter, amount: i32) Result(.{}) {
        self.count += amount;
        return Result(.{}).ok(.{});
    }

    pub fn toString(z: *zua.Zua, self: *Counter) Result([]const u8) {
        const msg = std.fmt.allocPrint(z.allocator, "Counter({d})", .{self.count}) catch
            return Result([]const u8).errStatic("out of memory");
        return Result([]const u8).owned(msg);
    }
};

// Functions to create our types
fn makeCounter(_: *zua.Zua) Result(Counter) {
    return Result(Counter).ok(Counter{ .count = 0 });
}

fn makeVector(x: f64, y: f64) Result(Vector2) {
    return Result(Vector2).ok(Vector2{ .x = x, .y = y });
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    // Register functions
    globals.setFn("add", zua.ZuaFn.pure(add, .{}));
    globals.setFn("multiply", zua.ZuaFn.pure(multiply, .{}));
    globals.setFn("Counter", zua.ZuaFn.from(makeCounter, .{}));
    globals.setFn("Vector", zua.ZuaFn.pure(makeVector, .{ .parse_error = "Vector expects (number, number)" }));

    try z.exec(
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
        \\print("\nAll features demonstrated!")
    );
}
