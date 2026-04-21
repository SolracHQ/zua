# REPL

zua ships a full interactive REPL that you can drop into any project with a single call. It handles multi-line input, persistent history, tab completion, and ANSI syntax highlighting. The prompt knows when an expression is incomplete, an unclosed `do` block or a function without `end`, and switches to a continuation prompt automatically.

## The minimal REPL

```zig
pub fn main(init: std.process.Init) !void {
    const z = try zua.State.init(init.gpa, init.io);
    defer z.deinit();

    try zua.Repl.run(z, .{});
}
```

That gives you a working Lua shell. Type expressions, call functions, define variables, paste multi-line code, and hit Ctrl-D to exit.

## Registering your API

Register globals the same way you do everywhere else, before calling `run`:

```zig
var ctx = zua.Context.init(z);
defer ctx.deinit();

const globals = z.globals();
defer globals.release();

try globals.set(&ctx, "add",   add);
try globals.set(&ctx, "greet", zua.ZuaFn.new(greet, .{}));

try zua.Repl.run(z, .{});
```

## Configuration

`zua.Repl.run` takes a `Config` struct. Every field is optional; defaults give you a working shell out of the box.

```zig
try zua.Repl.run(z, .{
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

try zua.Repl.run(z, .{
    .completion_callback = complete,
});
```

## Syntax highlighting

Pass a `color_config` to color Lua source as the user types:

```zig
try zua.Repl.run(z, .{
    .color_config = zua.Repl.highlight.ColorConfig{
        .keyword       = .{ .color = .{ .ansi = 93 }, .bold = true },
        .keyword_value = .{ .color = .{ .ansi = 96 } },
        .builtin       = .{ .color = .{ .ansi = 32 } },
        .string        = .{ .color = .{ .ansi = 34 } },
        .integer       = .{ .color = .{ .ansi = 95 } },
        .number        = .{ .color = .{ .ansi = 95 } },
        .symbol        = .{ .color = .{ .ansi = 33 } },
        .comment       = .{ .color = .{ .ansi = 90 }, .dim = true },
        .name          = .{ .color = .{ .ansi = 37 } },
    },
});
```

Fields left unset use their defaults (no color). Set `.ansi` for a standard terminal color code or `.rgb` for a 24-bit color if your terminal supports it. `.bold` and `.dim` apply on top of any color.

## Custom identifier classification

The highlighter knows Lua keywords, builtins, strings, and numbers. It does not know your API. Use `identifier_hook` to teach it:

```zig
fn myIdentifier(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "my_") or
           std.mem.eql(u8, text, "greet");
}

fn myColor(text: []const u8) zua.Repl.highlight.Color {
    _ = text;
    return .{ .rgb = .{ .r = 160, .g = 32, .b = 240 } };
}

try zua.Repl.run(z, .{
    .identifier_hook = myIdentifier,
    .color_config    = zua.Repl.highlight.ColorConfig{
        .custom = myColor,
        // ... other colors
    },
});
```

When `identifier_hook` returns `true` for a name, the lexer classifies it as `.custom` and the highlighter calls your `custom` color function. The function receives the text so you can vary the color by name if you want.

## Evaluation context

Each line typed at the REPL runs in a fresh `Context`, so arena-allocated scratch memory from one line does not carry over to the next. Global state in the Lua VM persists normally, so variables and functions defined at the prompt remain available for the rest of the session.

## Full example

```zig
const std = @import("std");
const zua = @import("zua");

fn example() []const u8 {
    return "this is just an example";
}

fn customIdentifier(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "custom_");
}

fn customColor(text: []const u8) zua.Repl.highlight.Color {
    _ = text;
    return .{ .rgb = .{ .r = 160, .g = 32, .b = 240 } };
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
    const z = try zua.State.init(init.gpa, init.io);
    defer z.deinit();

    var ctx = zua.Context.init(z);
    defer ctx.deinit();

    const globals = z.globals();
    defer globals.release();
    try globals.set(&ctx, "example",      example);
    try globals.set(&ctx, "custom_magic", example);

    try zua.Repl.run(z, .{
        .welcome_message     = "Welcome to the zua REPL!\n",
        .history_path        = "zua_repl_history.txt",
        .completion_callback = completionCallback,
        .identifier_hook     = customIdentifier,
        .color_config        = zua.Repl.highlight.ColorConfig{
            .keyword       = .{ .color = .{ .ansi = 93 }, .bold = true },
            .keyword_value = .{ .color = .{ .ansi = 96 } },
            .builtin       = .{ .color = .{ .ansi = 32 } },
            .custom        = customColor,
            .name          = .{ .color = .{ .ansi = 37 } },
            .string        = .{ .color = .{ .ansi = 34 } },
            .integer       = .{ .color = .{ .ansi = 95 } },
            .number        = .{ .color = .{ .ansi = 95 } },
            .symbol        = .{ .color = .{ .ansi = 33 } },
            .comment       = .{ .color = .{ .ansi = 90 }, .dim = true },
        },
    });
}
```
