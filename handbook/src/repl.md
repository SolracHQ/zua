# REPL

zua ships a full interactive REPL that you can drop into any project with a single call. It handles multi-line input, persistent history, tab completion, and ANSI syntax highlighting. The prompt knows when an expression is incomplete, an unclosed `do` block or a function without `end`, and switches to a continuation prompt automatically.

## The minimal REPL

```zig
pub fn main(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    try zua.Repl.run(state, .{});
}
```

That gives you a working Lua shell. Type expressions, call functions, define variables, paste multi-line code, and hit Ctrl-D to exit.

## Registering your API

Register globals the same way you do everywhere else, before calling `run`:

```zig
var ctx = zua.Context.init(state);
defer ctx.deinit();

try state.addGlobals(&ctx, .{
    .add = add,
    .greet = zua.ZuaFn.new(greet, .{}),
});

try zua.Repl.run(state, .{});
```

## Configuration

`zua.Repl.run` takes a `Config` struct. Every field is optional; defaults give you a working shell out of the box.

```zig
try zua.Repl.run(state, .{
    .prompt              = "myapp> ",
    .continuation_prompt = "   ... ",
    .welcome_message     = "Welcome! Type 'help' for hints.\n",
    .history_path        = "myapp_history.txt",
});
```

`history_path` enables persistent history across sessions. The file is created if it does not exist, loaded on startup, and saved after each line.

## Tab completion

Pass a `completion_callback` to hook into the line editor. The callback receives the current buffer and a `*Completions` value you push candidates onto:

```zig
fn complete(buffer: []const u8, completions: *zua.Repl.linenoise.Completions) void {
    const candidates = &[_][:0]const u8{ "add", "greet", "print", "tostring" };
    for (candidates) |c| {
        if (std.mem.startsWith(u8, c, buffer)) {
            zua.Repl.linenoise.addCompletion(completions, c);
        }
    }
}

try zua.Repl.run(state, .{
    .completion_callback = complete,
});
```

## Syntax highlighting

Pass a `color_hook` to color Lua source as the user types:

```zig
fn colorize(kind: zua.Repl.highlight.TokenKind, text: []const u8) ?zua.Repl.highlight.Style {
    return switch (kind) {
        .keyword => .{ .fg = .{ .ansi = 93 }, .bold = true },
        .keyword_value => .{ .fg = .{ .ansi = 96 } },
        .builtin => .{ .fg = .{ .ansi = 32 } },
        .name => if (std.mem.startsWith(u8, text, "my_"))
            .{ .fg = .{ .rgb = .{ .r = 160, .g = 32, .b = 240 } } }
        else
            .{ .fg = .{ .ansi = 37 } },
        .string => .{ .fg = .{ .ansi = 34 } },
        .integer, .number => .{ .fg = .{ .ansi = 95 } },
        .symbol => .{ .fg = .{ .ansi = 33 } },
        .comment => .{ .fg = .{ .ansi = 90 }, .dim = true },
    };
}

try zua.Repl.run(state, .{
    .color_hook = colorize,
});
```

Return `null` when you want the default style. Return a `Style` when you want to override it.

The hook gets both the token kind and the token text, so there is no separate identifier hook anymore. If you want to color your own globals, branch on `.name` and inspect the text there.

## Evaluation context

Each line typed at the REPL runs in a fresh `Context`, so arena-allocated scratch memory from one line does not carry over to the next. Global state in the Lua VM persists normally, so variables and functions defined at the prompt remain available for the rest of the session.

## Full example

```zig
const std = @import("std");
const zua = @import("zua");

fn example() []const u8 {
    return "this is just an example";
}

fn completionCallback(buffer: []const u8, completions: *zua.Repl.linenoise.Completions) void {
    const items = &[_][:0]const u8{ "example", "custom_magic", "custom_value", "print" };
    for (items) |item| {
        if (std.mem.startsWith(u8, item, buffer)) {
            zua.Repl.linenoise.addCompletion(completions, item);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    try state.addGlobals(&ctx, .{
        .example = example,
        .custom_magic = example,
    });

    const highlight = zua.Repl.highlight;

    try zua.Repl.run(state, .{
        .welcome_message     = "Welcome to the zua REPL!\n",
        .history_path        = "zua_repl_history.txt",
        .completion_callback = completionCallback,
        .color_hook = struct {
            fn colorize(kind: highlight.TokenKind, text: []const u8) ?highlight.Style {
                return switch (kind) {
                    .keyword => .{ .fg = .{ .ansi = 93 }, .bold = true },
                    .keyword_value => .{ .fg = .{ .ansi = 96 } },
                    .builtin => .{ .fg = .{ .ansi = 32 } },
                    .name => if (std.mem.startsWith(u8, text, "custom_"))
                        .{ .fg = .{ .rgb = .{ .r = 160, .g = 32, .b = 240 } } }
                    else
                        .{ .fg = .{ .ansi = 37 } },
                    .string => .{ .fg = .{ .ansi = 34 } },
                    .integer, .number => .{ .fg = .{ .ansi = 95 } },
                    .symbol => .{ .fg = .{ .ansi = 33 } },
                    .comment => .{ .fg = .{ .ansi = 90 }, .dim = true },
                };
            }
        }.colorize,
    });
}
```
