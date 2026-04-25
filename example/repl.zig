const std = @import("std");
const zua = @import("zua");
const REPL = zua.Repl;
const highlight = REPL.highlight;
const isocline = REPL.isocline;

/// A simple global function exported into the REPL.
///
/// This function is callable from Lua as `example()`.
fn example() []const u8 {
    return "this is just an example";
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
fn completionCallback(completer: *REPL.Completer, _: []const u8, arg: ?*anyopaque) void {
    _ = arg;

    const items = &[_][:0]const u8{ "example", "custom_magic", "custom_value", "print" };
    for (items) |item| {
        _ = completer.add(item);
    }
}

pub fn main(init: std.process.Init) !void {
    // Initialize the Zua state, which manages the Lua environment and resources.
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    // Each REPL line executes with a fresh Context for scratch allocation.
    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    const example_fn = zua.Native.new(example, .{})
        .withName("example")
        .withDescription("Return a sample string from the host environment.");
    const custom_magic_fn = zua.Native.new(example, .{})
        .withName("custom_magic")
        .withDescription("Alias for example() exposed for custom syntax highlighting.");

    // Register host functions into the Lua REPL environment.
    try state.addGlobals(&ctx, .{
        .example = example_fn,
        .custom_magic = custom_magic_fn,
    });

    try zua.Repl.run(state, .{
        // First line shown when the REPL starts.
        .welcome_message = "Welcome to Zua REPL with custom lexer and multi line support!\nshift+tab for multiline input, ctrl+d to exit.\n",
        // Path to save REPL command history across sessions.
        .history_path = "zua_repl_history.txt",
        // Custom syntax highlighting rules for the REPL input.
        .completion_hook = completionCallback,
        // you can customize all the token kinds.
        .color_hook = colorize,
        .stack_trace = true,
    });
}

fn colorize(kind: highlight.TokenKind, text: []const u8) ?highlight.Style {
    return switch (kind) {
        .keyword => .{ .fg = .{ .ansi = 93 }, .bold = true },
        .keyword_value => .{ .fg = .{ .ansi = 96 } },
        .builtin => .{ .fg = .{ .ansi = 32 } },
        .name => if (std.mem.startsWith(u8, text, "custom_")) .{ .fg = .{ .rgb = .{ .r = 160, .g = 32, .b = 240 } } } else .{ .fg = .{ .ansi = 37 } },
        .string => .{ .fg = .{ .ansi = 34 } },
        .integer, .number => .{ .fg = .{ .ansi = 95 } },
        .symbol => .{ .fg = .{ .ansi = 33 } },
        .comment => .{ .fg = .{ .ansi = 90 }, .dim = true },
    };
}
