const std = @import("std");
const zua = @import("zua");
const REPL = zua.Repl;
const highlight = REPL.highlight;
const linenoise = REPL.linenoise;

/// A simple global function exported into the REPL.
///
/// This function is callable from Lua as `example()`.
fn example() []const u8 {
    return "this is just an example";
}

/// Identify application-specific names for custom syntax highlighting.
///
/// Names starting with `custom_` are marked as special identifiers.
fn customIdentifier(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "custom_");
}

/// Assign a custom color to identifiers recognized by `customIdentifier`.
/// Can dynamically match several patterns, but for the example, all `custom_` identifiers share the same color.
fn customColor(text: []const u8) highlight.Color {
    _ = text;
    return .{ .rgb = .{ .r = 160, .g = 32, .b = 240 } };
}

/// Provide tab completion candidates from a custom list.
///
/// Completion is offered for matching names as the user types.
fn completionCallback(buffer: []const u8, completions: *linenoise.Completions) void {
    const items = &[_][:0]const u8{ "example", "custom_magic", "custom_value", "print" };
    for (items) |item| {
        if (std.mem.startsWith(u8, item, buffer)) {
            linenoise.addCompletion(completions, item);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    // Initialize the Zua state, which manages the Lua environment and resources.
    const z = try zua.State.init(init.gpa, init.io);
    defer z.deinit();

    // Each REPL line executes with a fresh Context for scratch allocation.
    var ctx = zua.Context.init(z);
    defer ctx.deinit();

    const globals = z.globals();
    defer globals.release();

    // Register host functions into the Lua REPL environment.
    globals.set(&ctx, "example", example);
    globals.set(&ctx, "custom_magic", example);

    try zua.Repl.run(z, .{
        // First line shown when the REPL starts.
        .welcome_message = "Welcome to Zua REPL with custom lexer support!\n",
        // Path to save REPL command history across sessions.
        .history_path = "zua_repl_history.txt",
        // Custom syntax highlighting rules for the REPL input.
        .completion_callback = completionCallback,
        // Selector function to identify special tokens for custom highlighting.
        .identifier_hook = customIdentifier,
        // you can customize all the token kinds.
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
