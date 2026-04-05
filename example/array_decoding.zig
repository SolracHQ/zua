const std = @import("std");
const zua = @import("zua");

const Zua = zua.Zua;
const Result = zua.Result;
const ZuaFn = zua.ZuaFn;

/// Sums all integers in a slice
fn sumIntegers(numbers: []const []const i32) Result(i32) {
    var sum: i32 = 0;
    for (numbers) |nums| {
        for (nums) |num| {
            sum += num;
        }
    }
    return Result(i32).ok(sum);
}

/// Counts and prints string elements in a slice
fn countStrings(z: *Zua, strings: []const []const u8) !Result(i32) {
    for (strings, 0..) |s, i| {
        const msg = std.fmt.allocPrint(z.allocator, "print('  [{d}] {s}')", .{ i + 1, s }) catch return Result(i32).errStatic("out of memory");
        defer z.allocator.free(msg);
        z.exec(msg) catch return Result(i32).errStatic("exec failed");
    }
    return Result(i32).ok(@intCast(strings.len));
}

/// Returns the maximum value in a slice of floats
fn maxFloat(values: []const f64) Result(f64) {
    if (values.len == 0) return Result(f64).errStatic("empty slice");

    var max_val = values[0];
    for (values[1..]) |val| {
        if (val > max_val) max_val = val;
    }
    return Result(f64).ok(max_val);
}

pub fn main(init: std.process.Init) !void {
    const z = try Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    // Register functions that accept slices
    globals.setFn("sum_integers", ZuaFn.pure(sumIntegers, .{ .parse_error = "sum_integers expects (numbers: []i32)" }));
    globals.setFn("count_strings", ZuaFn.from(countStrings, .{ .parse_error = "count_strings expects (strings: [][]const u8)" }));
    globals.setFn("max_float", ZuaFn.pure(maxFloat, .{ .parse_error = "max_float expects (values: []f64)" }));

    try z.exec(
        \\-- Test summing integers from a Lua array table
        \\local numbers = {{10, 20, 30, 40}}
        \\local result = sum_integers(numbers)
        \\print(string.format("sum_integers({10, 20, 30, 40}) = %d", result))
        \\assert(result == 100, string.format("expected 100, got %d", result))
    );

    try z.exec(
        \\-- Test counting and printing strings
        \\local fruits = {"apple", "banana", "cherry"}
        \\print(string.format("Iterating %d fruits:", count_strings(fruits)))
    );

    try z.exec(
        \\-- Test finding max value
        \\local temperatures = {72.5, 68.3, 75.9, 70.1}
        \\local max_temp = max_float(temperatures)
        \\print(string.format("max_float({72.5, 68.3, 75.9, 70.1}) = %.1f", max_temp))
        \\assert(max_temp == 75.9, string.format("expected 75.9, got %.1f", max_temp))
    );

    try z.exec(
        \\-- Verify empty arrays trigger errors
        \\local empty = {}
        \\local ok, err = pcall(max_float, empty)
        \\assert(not ok, "empty array should error")
        \\print(string.format("empty array error (expected): %s", err))
    );

    try z.exec(
        \\print("\nAll array decoding tests passed!")
    );
}
