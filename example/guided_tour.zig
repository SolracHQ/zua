const std = @import("std");
const zua = @import("zua");

const Zua = zua.Zua;
const Result = zua.Result;
const Table = zua.Table;

const AppState = struct {
    next_ticket: i32,
};

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    var app_state = AppState{ .next_ticket = 1000 };
    const tag_values = [_][]const u8{ "zig", "lua", "bindings" };

    const globals = z.globals();
    defer globals.pop();

    globals.set("greeting", "hello");
    globals.set("answer", 41);

    const guide = z.tableFrom(.{
        .name = "guided-tour",
        .tags = tag_values,
        .version = 1,
    });
    globals.set("guide", guide);
    guide.pop();

    globals.set("paths", .{
        .root = "usr",
        .segments = [_][]const u8{ "local", "bin" },
    });

    const counter = z.tableFrom(.{ .count = 2 });
    counter.setFn("increment", zua.ZuaFn.from(increment, "counter:increment expects (self, i32)"));
    globals.set("counter", counter);
    counter.pop();

    globals.setFn("add", zua.ZuaFn.from(add, "add expects (i32, i32)"));
    globals.setFn("join_path", zua.ZuaFn.from(joinPath, "join_path expects (string, string, string)"));
    globals.setFn("next_ticket", zua.ZuaFn.from(nextTicket, "next_ticket expects ()"));
    globals.setFn("printConfig", zua.ZuaFn.pure(printConfig, "printConfig expects (table)"));

    const registry = z.registry();
    defer registry.pop();
    registry.setLightUserdata("app_state", &app_state);

    try z.exec(
        \\message = greeting .. ", world"
        \\counter:increment(5)
        \\path = join_path(paths.root, paths.segments[1], paths.segments[2])
        \\printConfig({ name = "config-example", version = 42 })
    );

    const parsed = try z.eval(.{ []const u8, i32, i32, i32, []const u8, []const u8 },
        \\return message, add(answer, 1), counter.count, next_ticket(), guide.tags[2], path
    );
    std.debug.print("message={s}\n", .{parsed[0]});
    std.debug.print("sum={d}\n", .{parsed[1]});
    std.debug.print("counter={d}\n", .{parsed[2]});
    std.debug.print("ticket={d}\n", .{parsed[3]});
    std.debug.print("tag={s}\n", .{parsed[4]});
    std.debug.print("path={s}\n", .{parsed[5]});

    // getStruct reads all fields in one call and returns a typed Zig struct.
    const guide_table = try globals.get("guide", zua.Table);
    defer guide_table.pop();
    const guide_data = try zua.translation.decodeStruct(zua.Table, guide_table, struct {
        name: []const u8,
        version: i32,
    });
    std.debug.print("guide.name={s} guide.version={d}\n", .{ guide_data.name, guide_data.version });
}

fn add(_: *Zua, a: i32, b: i32) Result(i32) {
    return Result(i32).ok(a + b);
}

fn increment(_: *Zua, self_table: Table, delta: i32) Result(i32) {
    const next_value = (self_table.get("count", i32) catch return Result(i32).errStatic("counter.count missing")) + delta;
    self_table.set("count", next_value);
    return Result(i32).ok(next_value);
}

fn joinPath(z: *Zua, a: []const u8, b: []const u8, c: []const u8) Result([]const u8) {
    const joined = std.fmt.allocPrint(z.allocator, "{s}/{s}/{s}", .{ a, b, c }) catch {
        return Result([]const u8).errStatic("out of memory");
    };
    defer z.allocator.free(joined);
    return Result([]const u8).owned(z.allocator, joined);
}

fn nextTicket(z: *Zua) Result(i32) {
    const registry = z.registry();
    defer registry.pop();
    const app = registry.getLightUserdata("app_state", AppState) catch return Result(i32).errStatic("app state missing");
    app.next_ticket += 1;
    return Result(i32).ok(app.next_ticket - 1);
}

fn printConfig(config: struct {
    name: []const u8,
    version: i32,
}) Result(.{}) {
    std.debug.print("config.name={s} config.version={d}\n", .{ config.name, config.version });
    return Result(.{}).ok(.{});
}
