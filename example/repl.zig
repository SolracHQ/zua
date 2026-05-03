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

const SampleItems = [_]i32{ 10, 20, 30 };

const TestList = struct {
    pub const ZUA_META = zua.Meta.List(TestList, getElements, .{
        .__tostring = display,
        .sum = sum,
    }, .{});

    items: []const i32,

    pub fn getElements(self: *TestList) []const i32 {
        return self.items;
    }

    pub fn sum(self: *TestList) i32 {
        var total: i32 = 0;
        for (self.items) |item| total += item;
        return total;
    }

    pub fn display(_: *TestList) []const u8 {
        return "TestList";
    }
};

/// Assign a custom color to identifiers recognized by `customIdentifier`.
/// Can dynamically match several patterns, but for the example, all `custom_` identifiers share the same color.
fn customColor(text: []const u8) highlight.Color {
    _ = text;
    return .{ .rgb = .{ .r = 160, .g = 32, .b = 240 } };
}

/// Provide tab completion candidates from a custom list.
///
/// Completion is offered for matching names as the user types.
fn completionCallback(completer: *REPL.Completer, prefix: []const u8) void {
    const items = &[_][:0]const u8{ "example", "custom_magic", "custom_value", "print" };
    for (items) |item| {
        if (std.mem.startsWith(u8, item, prefix)) {
            _ = completer.addEx(item, null, "A custom completion candidate");
        }
    }
}

pub fn main(init: std.process.Init) !void {
    // Initialize the Zua state, which manages the Lua environment and resources.
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    // Each REPL line executes with a fresh Context for scratch allocation.
    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    const example_fn = zua.Native.new(example, .{}, .{
        .name = "example",
        .description = "Return a sample string from the host environment.",
    });
    const custom_magic_fn = zua.Native.new(example, .{}, .{
        .name = "custom_magic",
        .description = "Alias for example() exposed for custom syntax highlighting.",
    });

    // Register host functions and a sample list object into the Lua REPL environment.
    try state.addGlobals(&ctx, .{
        .example = example_fn,
        .custom_magic = custom_magic_fn,
        .test_list = TestList{ .items = SampleItems[0..] },
    });

    var repl_config = zua.Repl.Config{
        // First line shown when the REPL starts.
        .welcome_message = "Welcome to Zua REPL with custom lexer and multi line support!\nshift+tab for multiline input, ctrl+d to exit.\n",
        // Path to save REPL command history across sessions.
        .history_path = "zua_repl_history.txt",
        // Custom syntax highlighting rules for the REPL input.
        .completion_hook = completionCallback,
        // you can customize all the token kinds.
        .style_hook = colorize,
        .stack_trace = true,
        .runtime_completion = true,
    };
    try zua.Repl.run(state, &repl_config);
}

fn colorize(ctx: *zua.Context, kind: highlight.TokenKind, text: []const u8) ?highlight.Style {
    _ = ctx;
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
