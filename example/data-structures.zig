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

fn printPoint(_: *zua.Context, p: Point) void {
    std.debug.print("Point({d}, {d})\n", .{ p.x, p.y });
}

fn createConfig(_: *zua.Context, name: []const u8, value: i32, enabled: bool) Config {
    return Config{ .name = name, .value = value, .enabled = enabled };
}

fn getConfigValue(ctx: *zua.Context, config: zua.Table) !?i32 {
    if (!config.has(1)) {
        return null;
    }
    return try config.get(ctx, 1, i32);
}

fn sumNumbers(ctx: *zua.Context, numbers_table: zua.Table) !i32 {
    var sum: i32 = 0;
    var i: i32 = 1;

    // Iterate over array table from index 1
    while (i <= 100) : (i += 1) {
        if (!numbers_table.has(i)) {
            break;
        }

        const num = try numbers_table.get(ctx, i, i32);
        sum += num;
    }

    return sum;
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.State.init(init.gpa, init.io);
    defer z.deinit();
    var executor = zua.Executor{};
    var ctx = zua.Context.init(z);
    defer ctx.deinit();

    const globals = z.globals();
    defer globals.release();

    globals.set(&ctx, "print_point", zua.Native.new(printPoint, .{ .parse_err_fmt = "print_point expects (table): {s}" }));
    globals.set(&ctx, "create_config", zua.Native.new(createConfig, .{ .parse_err_fmt = "create_config expects (string, number, boolean): {s}" }));
    globals.set(&ctx, "get_config_value", zua.Native.new(getConfigValue, .{ .parse_err_fmt = "get_config_value expects (table): {s}" }));
    globals.set(&ctx, "sum_numbers", zua.Native.new(sumNumbers, .{ .parse_err_fmt = "sum_numbers expects (table): {s}" }));

    try executor.execute(&ctx, .{ .code = .{ .string =
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
    } });
}
