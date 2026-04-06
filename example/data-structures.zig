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

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa, init.io);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("print_point", zua.ZuaFn.from(printPoint, .{ .parse_error = "print_point expects (table)" }));
    globals.setFn("create_config", zua.ZuaFn.from(createConfig, .{ .parse_error = "create_config expects (string, number, boolean)" }));

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
    );
}
