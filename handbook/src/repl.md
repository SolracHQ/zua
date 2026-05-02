# REPL

zua ships a full interactive REPL that you can drop into any project with a single call. It handles multi-line input, persistent history, tab completion, and ANSI syntax highlighting. The current backend gives you real multiline editing, so you can move around and edit anywhere in the block instead of only editing the last line.

> [!NOTE]
> The new line-editor backend is actually more capable than the old one. The old REPL only supported multiline input by guessing unfinished `do`/`end` blocks and that logic was complicated and half-broken. Now you can add new lines natively with Shift+Tab without evaluating them first, so the code is much simpler and more reliable.

> [!TIP]
> If someone really liked the old behavior, open an issue. I can add a completion hook or something to make it optional. I really love hooks :3

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
    .greet = zua.Native.new(greet, .{}),
});

try zua.Repl.run(state, .{});
```

## Configuration

`zua.Repl.run` takes a `Config` struct. Every field is optional; defaults give you a working shell out of the box.

```zig
try zua.Repl.run(state, .{
    .prompt          = "myapp",
    .welcome_message = "Welcome! Type 'help' for hints.\n",
    .history_path    = "myapp_history.txt",
    .stack_trace     = true,
});
```

`history_path` enables persistent history across sessions. The file is created if it does not exist, loaded on startup, and saved after each line.

`stack_trace` enables Lua traceback capture for runtime errors, which is useful when you want more than just the final error message.

## Tab completion

Pass a `completion_hook` to add completions. The callback receives the current prefix and a stable `*zua.Repl.Completer` helper that does not expose the underlying line-editor internals:

```zig
fn complete(completer: *zua.Repl.Completer, prefix: []const u8, arg: ?*anyopaque) void {
    const items = &[_][:0]const u8{ "add", "greet", "print", "tostring" };
    for (items) |item| {
        if (std.mem.startsWith(u8, item, prefix)) {
            _ = completer.add(item);
        }
    }
}

try zua.Repl.run(state, .{
    .completion_hook = complete,
});
```

The `Completer` API is the stable public hook surface. If we swap the line editor library again in the future, your completion callback still works.

Use `completer.addEx(candidate, display, help)` when you want a richer entry with alternate label or help text.

### Runtime Lua completion

When `lua_completion` is enabled, the REPL uses the live Lua runtime to complete globals, table fields, methods, and chained identifiers such as `foo.` and `foo:`.

This works alongside `completion_hook`: runtime completion is performed first, and then your custom hook is invoked so it can augment or override the results.

```zig
try zua.Repl.run(state, .{
    .completion_hook = complete,
    .lua_completion = true,
});
```

If you only want custom candidates and not live runtime completion, omit `lua_completion` and keep only `completion_hook`.

## Syntax highlighting

Pass a `color_hook` to color Lua source as the user types:

```zig
fn colorize(ctx: *zua.Context, kind: zua.Repl.highlight.TokenKind, text: []const u8) ?zua.Repl.highlight.Style {
    _ = ctx;
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
    .style_hook = colorize,
});
```

Return `null` when you want the default style, or a `Style` when you want to override it.

The hook receives a `*Context`, the token kind, and the token text. The context gives you access to the Lua state: read or modify globals, query the registry, or retrieve config stored by your host via a registry key. If you want to color your own globals, branch on `.name` and inspect the text.

## Stack traces

If you want nicer runtime errors during interactive sessions, enable `stack_trace`:

```zig
try zua.Repl.run(state, .{
    .stack_trace = true,
});
```

When enabled, runtime failures include a Lua traceback instead of only the final error line.

## Evaluation context

Each line typed at the REPL runs in a fresh `Context`, so arena-allocated scratch memory from one line does not carry over to the next. Global state in the Lua VM still persists normally, so variables and functions defined at the prompt remain available for the rest of the session.

## Full example

```zig
const std = @import("std");
const zua = @import("zua");

fn example() []const u8 {
    return "this is just an example";
}

fn completionCallback(completer: *zua.Repl.Completer, prefix: []const u8, arg: ?*anyopaque) void {
    _ = arg;
    const items = &[_][:0]const u8{ "example", "custom_magic", "custom_value", "print" };
    for (items) |item| {
        if (std.mem.startsWith(u8, item, prefix)) {
            _ = completer.add(item);
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

    try zua.Repl.run(state, .{
        .welcome_message = "Welcome to the zua REPL!\n",
        .history_path = "zua_repl_history.txt",
        .completion_hook = completionCallback,
        .style_hook = colorize,
        .stack_trace = true,
    });
}

fn colorize(ctx: *zua.Context, kind: zua.Repl.highlight.TokenKind, text: []const u8) ?zua.Repl.highlight.Style {
    _ = ctx;
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
```
