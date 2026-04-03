const std = @import("std");
const zua = @import("zua");

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    const config = zua.createTable(0, 3);
    config.set("name", "zua");
    config.set("version", 1);
    config.set("enabled", true);

    globals.set("config", config);
    config.pop();

    try zua.exec(
        \\print(config.name)
        \\print(config.version)
        \\print(config.enabled)
    );
}
