const std = @import("std");
const zua = @import("zua");

const Point = struct {
    x: f64,
    y: f64,
};

const Config = struct {
    name: []const u8,
    value: i32,
    enabled: bool,
};

fn printPoint(_: *zua.Zua, p: Point) zua.Result(.{}) {
    std.debug.print("Point({d}, {d})\n", .{ p.x, p.y });
    return zua.Result(.{}).ok(.{});
}

fn createConfig(_: *zua.Zua, name: []const u8, value: i32, enabled: bool) zua.Result(Config) {
    return zua.Result(Config).ok(Config{ .name = name, .value = value, .enabled = enabled });
}

fn getConfigValue(z: *zua.Zua, config: zua.Table) zua.Result(?i32) {
    if (!config.has(1)) {
        return zua.Result(?i32).ok(null);
    }
    const value = config.get(1, i32) catch |err| {
        return zua.Result(?i32).errOwned(z, "failed to get index 1: {s}", .{@errorName(err)});
    };
    if (value.failure) |failure| {
        return zua.Result(?i32).errOwned(z, "decode error: {s}", .{failure.getErr()});
    }
    return zua.Result(?i32).ok(value.value);
}

fn sumNumbers(z: *zua.Zua, numbers_table: zua.Table) zua.Result(i32) {
    var sum: i32 = 0;
    var i: i32 = 1;

    // Iterate over array table from index 1
    while (i <= 100) : (i += 1) {
        if (!numbers_table.has(i)) {
            break;
        }

        const num_result = numbers_table.get(i, i32) catch |err| {
            return zua.Result(i32).errOwned(z, "failed at index {d}: {s}", .{ i, @errorName(err) });
        };

        if (num_result.failure) |fail| {
            return zua.Result(i32).errOwned(z, "decode error at index {d}: {s}", .{ i, fail.getErr() });
        }

        sum += num_result.value;
    }

    return zua.Result(i32).ok(sum);
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa, init.io);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("print_point", zua.ZuaFn.from(printPoint, .{ .parse_err_fmt = "print_point expects (table): {s}" }));
    globals.setFn("create_config", zua.ZuaFn.from(createConfig, .{ .parse_err_fmt = "create_config expects (string, number, boolean): {s}" }));
    globals.setFn("get_config_value", zua.ZuaFn.from(getConfigValue, .{ .parse_err_fmt = "get_config_value expects (table): {s}" }));
    globals.setFn("sum_numbers", zua.ZuaFn.from(sumNumbers, .{ .parse_err_fmt = "sum_numbers expects (table): {s}" }));

    try z.exec(
        \\-- Create and pass tables
        \\local p = {x = 3.5, y = 4.2}
        \\print_point(p)
        \\
        \\-- Create structured data
        \\local cfg = create_config("my_config", 42, true)
        \\print("Config:", cfg.name, cfg.value, cfg.enabled)
        \\
        \\-- Access table fields
        \\print("Point x:", p.x)
        \\
        \\-- Check key existence and get by index
        \\print("get_config_value(cfg):", get_config_value(cfg))
        \\
        \\-- Process array tables
        \\local numbers = {10, 20, 30, 40}
        \\print("sum_numbers({10, 20, 30, 40}):", sum_numbers(numbers))
    );
}
