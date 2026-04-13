const std = @import("std");
const zua = @import("zua");
const REPL = zua.Repl;
const highlight = REPL.highlight;
const linenoise = REPL.linenoise;

fn example() []const u8 {
    return "this is just an example";
}

fn customIdentifier(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "custom_");
}

fn customColor(text: []const u8) highlight.Color {
    _ = text;
    return .{ .rgb = .{ .r = 160, .g = 32, .b = 240 } };
}

fn completionCallback(buffer: []const u8, completions: *linenoise.Completions) void {
    const items = &[_][:0]const u8{ "example", "custom_magic", "custom_value", "print" };
    for (items) |item| {
        if (std.mem.startsWith(u8, item, buffer)) {
            linenoise.addCompletion(completions, item);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.State.init(init.gpa, init.io);
    defer z.deinit();

    var ctx = zua.Context.init(z);
    defer ctx.deinit();

    const globals = z.globals();
    defer globals.release();
    globals.set(&ctx, "example", example);
    globals.set(&ctx, "custom_magic", example);

    try zua.Repl.run(z, .{
        .welcome_message = "Welcome to Zua REPL with custom lexer support!\n",
        .history_path = "zua_repl_history.txt",
        .completion_callback = completionCallback,
        .identifier_hook = customIdentifier,
        .color_config = highlight.ColorConfig{
            .keyword = .{ .color = .{ .ansi = 93 }, .bold = true },
            .keyword_value = .{ .color = .{ .ansi = 96 } },
            .builtin = .{ .color = .{ .ansi = 32 } },
            .custom = customColor,
            .name = .{ .color = .{ .ansi = 37 } },
            .string = .{ .color = .{ .ansi = 34 } },
            .integer = .{ .color = .{ .ansi = 95 } },
            .number = .{ .color = .{ .ansi = 95 } },
            .symbol = .{ .color = .{ .ansi = 33 } },
            .comment = .{ .color = .{ .ansi = 90 }, .dim = true },
        },
    });
}
