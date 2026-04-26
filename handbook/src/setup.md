# Setup

Every zua program starts with three things: a `State`, a `Context`, and an `Executor`. This chapter sets up the full environment and runs a first piece of Lua code.

## State

`State` is the Lua VM. It owns the allocator, the Lua state pointer, and all the global tables.

```zig
const state = try zua.State.init(allocator, io);
defer state.deinit();
```

`State.init` takes a general-purpose allocator and a `std.Io` handle. The `io` handle is how zua participates in Zig's I/O system, which controls where Lua's `print` sends output and how file operations are routed. In a standard `main`, both are available directly from `init`:

```zig
pub fn main(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();
}
```

`State` is heap-allocated internally and holds a stable pointer, so passing `*State` around through callbacks is safe.

## Context

`Context` is the per-call environment. It owns the arena allocator used during a single Lua call, carries any error message the call produced, and is passed to most zua functions.

```zig
var ctx = zua.Context.init(state);
defer ctx.deinit();
```

You create one `Context` and reuse it across calls. The arena is reset internally on each `execute` or `eval`, so scratch memory from one call does not carry over to the next. The [Context and arena](./context-and-arena.md) chapter covers this in detail.

## Executor

`Executor` runs Lua code. It is a plain struct with no required initialization.

```zig
var executor = zua.Executor{};
```

Use `execute` to run code for side effects:

```zig
try executor.execute(&ctx, .{ .code = .{ .string = "print('hello')" } });
```

Use `eval` to run code and decode the return value into a Zig type:

```zig
const result = try executor.eval(&ctx, i32, .{ .code = .{ .string = "return 1 + 2" } });
// result == 3
```

The second argument to `eval` is the Zig type you expect back. zua decodes the Lua return value into it and returns an error if the types do not match. Both `execute` and `eval` accept a string or a file path as source:

```zig
.{ .code = .{ .string = "return 42" } }
.{ .code = .{ .file = "script.lua" } }
```

## Globals

To expose functions and values to Lua, prefer `state.addGlobals(&ctx, .{ ... })`:

```zig
try state.addGlobals(&ctx, .{
    .add = add,
});
```

This is the short path for filling the globals table from a module-like struct literal. If you need the raw globals handle because you are doing something more manual, `state.globals()` is still there.

## Putting it together

Here is the minimal program that registers a function and calls it from Lua:

```zig
const std = @import("std");
const zua = @import("zua");

fn add(a: i32, b: i32) i32 {
    return a + b;
}

pub fn main(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    var executor = zua.Executor{};
    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    try state.addGlobals(&ctx, .{ .add = add });

    try executor.execute(&ctx, .{ .code = .{ .string = "print(add(1, 2))" } });
}
```

This prints `3`. Everything else in the handbook builds on this same skeleton.