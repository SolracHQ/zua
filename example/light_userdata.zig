const std = @import("std");
const zua = @import("zua");

const AppState = struct {
    next: i32,
};

fn nextValue(z: *zua.Zua) zua.Result(i32) {
    const registry = z.registry();
    defer registry.pop();

    const app = registry.getLightUserdata("app_context", AppState) catch return zua.Result(i32).errStatic("app context missing");
    app.next += 1;
    return zua.Result(i32).ok(app.next - 1);
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    var app = AppState{ .next = 1 };

    const registry = z.registry();
    defer registry.pop();
    registry.setLightUserdata("app_context", &app);

    const globals = z.globals();
    defer globals.pop();
    globals.setFn("next_value", zua.ZuaFn.from(nextValue, .{ .parse_error = "next_value expects ()" }));

    try z.exec(
        \\print(next_value())
        \\print(next_value())
        \\print(next_value())
    );
}
