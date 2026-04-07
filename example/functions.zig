const std = @import("std");
const zua = @import("zua");

const Result = zua.Result;

fn add(a: i32, b: i32) Result(i32) {
    return Result(i32).ok(a + b);
}

fn greet(z: *zua.Zua, name: []const u8) Result([]const u8) {
    const display = std.fmt.allocPrint(
        z.allocator,
        "Hello, {s}!",
        .{name},
    ) catch return Result([]const u8).errStatic("out of memory");
    return Result([]const u8).owned(display);
}

fn safeDivide(_: *zua.Zua, a: f64, b: f64) Result(f64) {
    if (b == 0.0) {
        return Result(f64).errStatic("division by zero");
    }
    return Result(f64).ok(a / b);
}

fn applyTwice(_: *zua.Zua, callback: zua.Function(.{i32}), initial: i32) Result(i32) {
    var current = initial;

    // First call
    const result1 = callback.call(.{current}) catch {
        return Result(i32).errStatic("first call failed");
    };
    if (result1.failure) |fail| {
        return Result(i32).errStatic(fail.getErr());
    }
    current = result1.values[0];

    // Second call
    const result2 = callback.call(.{current}) catch {
        return Result(i32).errStatic("second call failed");
    };
    if (result2.failure) |fail| {
        return Result(i32).errStatic(fail.getErr());
    }
    return Result(i32).ok(result2.values[0]);
}

/// CallbackRegistry: an Object type that stores a callback for later use.
/// Demonstrates the Object strategy with callback ownership.
const CallbackRegistry = struct {
    // Marker for Object strategy
    pub const ZUA_META = zua.meta.Object(CallbackRegistry, .{
        .set_callback = setCallback,
        .call_stored = callStored,
        .__gc = deinit, // Ensure we release owned callback on GC
    });

    // Stores owned callback, null if not set
    stored: ?zua.Function(.{i32}) = null,

    /// Store a callback by taking ownership
    pub fn setCallback(self: *CallbackRegistry, callback: zua.Function(.{i32})) Result(.{}) {
        // Release previous callback if it exists
        if (self.stored) |prev| {
            prev.release();
        }

        // Take ownership of the new callback
        self.stored = callback.takeOwnership();
        return Result(.{}).ok(.{});
    }

    /// Call the stored callback with a value, or return default if not set
    pub fn callStored(self: *CallbackRegistry, value: i32) Result(i32) {
        if (self.stored) |callback| {
            const result = callback.call(.{value}) catch |err| {
                std.debug.print("ERROR calling stored callback: {any}\n", .{err});
                return Result(i32).errStatic("callback call failed");
            };
            if (result.failure) |fail| {
                return Result(i32).errStatic(fail.getErr());
            }
            return Result(i32).ok(result.values[0]);
        } else {
            // Default: return value unchanged if no callback set
            return Result(i32).ok(value);
        }
    }

    fn deinit(self: *CallbackRegistry) Result(.{}) {
        if (self.stored) |callback| {
            callback.release();
        }
        return Result(.{}).ok(.{});
    }
};

fn makeCallbackRegistry(_: *zua.Zua) Result(CallbackRegistry) {
    return Result(CallbackRegistry).ok(CallbackRegistry{});
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa, init.io);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("add", zua.ZuaFn.pure(add, .{ .parse_err_fmt = "add expects (number, number): {s}" }));
    globals.setFn("greet", zua.ZuaFn.from(greet, .{ .parse_err_fmt = "greet expects (string): {s}" }));
    globals.setFn("divide", zua.ZuaFn.from(safeDivide, .{ .parse_err_fmt = "divide expects (number, number): {s}" }));
    globals.setFn("apply_twice", zua.ZuaFn.from(applyTwice, .{ .parse_err_fmt = "apply_twice expects (function, number): {s}" }));
    globals.setFn("CallbackRegistry", zua.ZuaFn.from(makeCallbackRegistry, .{ .parse_err_fmt = "CallbackRegistry expects (): {s}" }));

    try z.exec(
        \\print("add(10, 20) =", add(10, 20))
        \\print(greet("Zig"))
        \\print("divide(10, 2) =", divide(10, 2))
        \\
        \\-- Receiving and calling Lua functions
        \\local increment = function(x) return x + 1 end
        \\print("apply_twice(increment, 5) =", apply_twice(increment, 5))
        \\
        \\-- Callback storage with Object strategy
        \\print("\nCallback Registry (Object type):")
        \\local registry = CallbackRegistry()
        \\
        \\-- Call without callback set (returns default value)
        \\print("registry:call_stored(10) =", registry:call_stored(10))
        \\
        \\-- Store a callback
        \\local triple = function(x) return x * 3 end
        \\registry:set_callback(triple)
        \\
        \\-- Call with stored callback
        \\print("registry:call_stored(10) =", registry:call_stored(10))
        \\
        \\-- Error handling with pcall
        \\local ok, result = pcall(divide, 10, 0)
        \\if not ok then
        \\    print("Caught error:", result)
        \\end
    );
}
