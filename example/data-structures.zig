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

fn printPoint(p: Point) void {
    std.debug.print("Point({d}, {d})\n", .{ p.x, p.y });
}

fn createConfig(name: []const u8, value: i32, enabled: bool) Config {
    return Config{ .name = name, .value = value, .enabled = enabled };
}

fn getConfigValue(ctx: *zua.Context, config: zua.Handlers.Any.Table) !?i32 {
    if (!config.has(1)) {
        return null;
    }
    return try config.get(ctx, 1, i32);
}

fn sumNumbers(ctx: *zua.Context, numbers_table: zua.Handlers.Any.Table) !i32 {
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

const Handle = opaque {
    pub const ZUA_SHAPE = zua.Shape.Ptr(Handle, .{ .name = "Handle" });
};

fn makeHandle(ctx: *zua.Context) !*Handle {
    const mem = try ctx.arena().alloc(u8, 1);
    return @ptrCast(@alignCast(mem.ptr));
}

fn inspectHandle(handle: *Handle) void {
    _ = handle;
    std.debug.print("got opaque handle via light userdata\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();
    var executor = zua.Executor{};
    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    try state.addGlobals(&ctx, .{
        .print_point = zua.Shape.Fn(printPoint, .{}),
        .create_config = zua.Shape.Fn(createConfig, .{}),
        .get_config_value = zua.Shape.Fn(getConfigValue, .{}),
        .sum_numbers = zua.Shape.Fn(sumNumbers, .{}),
        .make_handle = zua.Shape.Fn(makeHandle, .{}),
        .inspect_handle = zua.Shape.Fn(inspectHandle, .{}),
    });

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
        \\
        \\-- Opaque handle as light userdata (.ptr strategy)
        \\local h = make_handle()
        \\print("handle type:", type(h))
        \\inspect_handle(h)
    } });
}
