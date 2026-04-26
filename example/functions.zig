const std = @import("std");
const zua = @import("zua");

fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn greet(ctx: *zua.Context, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        ctx.arena(),
        "Hello, {s}!",
        .{name},
    ) catch try ctx.failTyped([]const u8, "out of memory");
}

fn safeDivide(ctx: *zua.Context, a: f64, b: f64) !f64 {
    if (b == 0.0) {
        return ctx.failTyped(f64, "division by zero");
    }
    return a / b;
}

fn applyTwice(ctx: *zua.Context, callback: zua.Function, initial: i32) !i32 {
    var current = initial;
    current = try callback.call(ctx, .{current}, i32);
    current = try callback.call(ctx, .{current}, i32);
    return current;
}

fn increment(x: i32) i32 {
    return x + 1;
}

// --- Closures ---

/// Captured state for a counter closure. The `Meta.Capture` strategy
/// stores this struct as upvalue 1 of the Lua C closure so mutations
/// persist across calls to the same closure instance.
const CounterState = struct {
    pub const ZUA_META = zua.Meta.Capture(@This(), .{});
    count: i32,
    step: i32,
};

/// Each call increments `count` by `step` and returns the new value.
// --- VarArgs ---

/// Sums all Lua number arguments passed in. Demonstrates VarArgs.
fn sumAll(ctx: *zua.Context, args: zua.VarArgs) !i64 {
    var total: i64 = 0;
    for (args.args) |prim| {
        switch (prim) {
            .integer => |i| total += i,
            .float => |f| total += @intFromFloat(f),
            else => return ctx.failTyped(i64, "sum_all expects numbers"),
        }
    }
    return total;
}

/// Describes the Lua type of each argument passed in.
fn describeArgs(ctx: *zua.Context, args: zua.VarArgs) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (args.args, 0..) |prim, i| {
        if (i > 0) try buf.appendSlice(ctx.arena(), ", ");
        try buf.appendSlice(ctx.arena(), @tagName(prim));
    }
    return buf.items;
}

fn counterTick(s: *CounterState) i32 {
    s.count += s.step;
    return s.count;
}

/// CallbackRegistry: an Object type that stores a callback for later use.
/// Demonstrates the Object strategy with callback ownership.
const CallbackRegistry = struct {
    // Marker for Object strategy
    pub const ZUA_META = zua.Meta.Object(CallbackRegistry, .{
        .set_callback = setCallback,
        .call_stored = callStored,
        .__gc = deinit,
    });

    // Stores owned callback, null if not set
    stored: ?zua.Fn(i32, i32) = null,

    /// Store a callback by taking ownership
    pub fn setCallback(self: *CallbackRegistry, callback: zua.Fn(i32, i32)) void {
        // Release previous callback if it exists
        if (self.stored) |prev| {
            prev.release();
        }

        // Take ownership of the new callback
        self.stored = callback.takeOwnership();
    }

    /// Call the stored callback with a value, or return default if not set
    pub fn callStored(ctx: *zua.Context, self: *CallbackRegistry, value: i32) !i32 {
        if (self.stored) |callback| {
            return try callback.call(ctx, value);
        } else {
            // Default: return value unchanged if no callback set
            return value;
        }
    }

    fn deinit(self: *CallbackRegistry) void {
        if (self.stored) |callback| {
            callback.release();
        }
    }
};

fn makeCallbackRegistry(_: *zua.Context) CallbackRegistry {
    return CallbackRegistry{};
}

pub fn main(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();
    var executor = zua.Executor{};
    var ctx = zua.Context.init(state);
    errdefer {
        std.debug.print("Error: {s}\n", .{ctx.err orelse "unknown"});
    }
    defer ctx.deinit();

    var increment_handle = zua.Function.create(state, increment);
    const owned_increment = increment_handle.takeOwnership();
    defer owned_increment.release();

    var typed_increment = zua.Fn(.{i32}, i32).create(&ctx, increment);
    const owned_typed_increment = typed_increment.takeOwnership();
    defer owned_typed_increment.release();

    const module = .{
        .add = zua.Native.new(add, .{ .parse_err_fmt = "add expects (number, number): {s}" }),
        .greet = zua.Native.new(greet, .{ .parse_err_fmt = "greet expects (string): {s}" }),
        .divide = zua.Native.new(safeDivide, .{ .parse_err_fmt = "divide expects (number, number): {s}" }),
        .apply_twice = zua.Native.new(applyTwice, .{ .parse_err_fmt = "apply_twice expects (function, number): {s}" }),
        .CallbackRegistry = zua.Native.new(makeCallbackRegistry, .{ .parse_err_fmt = "CallbackRegistry expects (): {s}" }),
        .increment = owned_increment,
        .typed_increment = owned_typed_increment,
        .sum_all = zua.Native.new(sumAll, .{ .parse_err_fmt = "sum_all expects numbers: {s}" }),
        .describe_args = zua.Native.new(describeArgs, .{ .parse_err_fmt = "describe_args expects any: {s}" }),
        .counter_by_one = zua.Native.closure(counterTick, CounterState{ .count = 0, .step = 1 }, .{}),
        .counter_by_ten = zua.Native.closure(counterTick, CounterState{ .count = 0, .step = 10 }, .{}),
    };

    try state.addGlobals(&ctx, module);

    try executor.execute(&ctx, .{ .code = .{ .string =
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
        \\
        \\-- Closures: captured state persists across calls
        \\print("\nClosures (captured mutable state):")
        \\print("counter_by_one:", counter_by_one())  -- 1
        \\print("counter_by_one:", counter_by_one())  -- 2
        \\print("counter_by_one:", counter_by_one())  -- 3
        \\print("counter_by_ten:", counter_by_ten())  -- 10
        \\print("counter_by_ten:", counter_by_ten())  -- 20
        \\-- The two counters are independent
        \\print("counter_by_one:", counter_by_one())  -- 4  (unaffected by by_ten calls)        \\
        \\-- VarArgs: capture remaining Lua arguments as []Primitive
        \\print("\nVarArgs:")
        \\print("sum_all(1, 2, 3, 4, 5) =", sum_all(1, 2, 3, 4, 5))
        \\print("sum_all() =", sum_all())
        \\print("describe_args(1, true, 'hello', 3.14) =", describe_args(1, true, "hello", 3.14))    
    } });
}
