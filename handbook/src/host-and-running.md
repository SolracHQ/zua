# Host State

Callbacks often need access to application state that Lua should not touch directly. The standard pattern is a light userdata pointer stored in the Lua registry.

## Storing state

```zig
var app = AppState{ .next_id = 1000 };

const registry = z.registry();
defer registry.pop();
registry.setLightUserdata("app", &app);
```

## Reading state inside a callback

```zig
fn nextId(z: *Zua) Result(i32) {
    const registry = z.registry();
    defer registry.pop();

    const app = registry.getLightUserdata("app", AppState)
        catch return Result(i32).errStatic("app state missing");
    app.next_id += 1;
    return Result(i32).ok(app.next_id - 1);
}
```

## Hidden pointer on a table

You can attach a private pointer directly to a Lua-facing table. This is useful when a table wraps a specific Zig value rather than shared global state:

```zig
const entry_table = z.createTable(0, 3);
entry_table.set("address", "0x7fff1234");
entry_table.setLightUserdata("_ptr", entry_ptr);
entry_table.setFn("get", ZuaFn.from(entryGet, .{
    .parse_error = "entry:get takes no arguments",
}));
```

Inside the method:

```zig
fn entryGet(z: *Zua, self: Table) Result(f64) {
    const entry = self.getLightUserdata("_ptr", Entry)
        catch return Result(f64).errStatic("entry pointer missing");
    _ = z;
    return Result(f64).ok(entry.read());
}
```

The `_ptr` naming convention signals to Lua authors that the field is private. Lua can still read it, but it is not part of the public API.

## Lifetime

Light userdata is a raw pointer. The pointed-to value must outlive the `Zua` instance. zua does not track or manage that lifetime.

# Running Lua

## Executing for side effects

```zig
try z.exec("print('hello world')");
```

Errors come back as Zig errors:

```zig
z.exec("bad lua here") catch |err| {
    std.debug.print("error: {}\n", .{err});
};
```

## Evaluating with typed return values

`eval` decodes Lua return values directly into a typed Zig tuple:

```zig
const result = try z.eval(i32, "return 1 + 2");

const data = try z.eval(.{ []const u8, i32 }, "return 'bob', 42");
std.debug.print("{s} is {d}\n", .{ data[0], data[1] });
```

## Files

```zig
try z.execFile("init.lua");

const config = try z.evalFile(.{ []const u8, i32 }, "config.lua");
```

## Error tracebacks

When you need the full Lua stack trace, use `execTraceback`:

```zig
const result = try z.execTraceback("bad code here");
defer z.freeTraceBackResult(result);

switch (result) {
    .Ok => {},
    .Runtime => |msg| std.debug.print("runtime error:\n{s}\n", .{msg}),
    .Syntax  => |msg| std.debug.print("syntax error:\n{s}\n", .{msg}),
    else     => |msg| std.debug.print("error:\n{s}\n", .{msg}),
}
```

Always call `freeTraceBackResult` to free the allocated message.

## Building a REPL

`checkChunk` tells you whether a piece of Lua source is syntactically complete or waiting for more input:

```zig
var buffer = std.ArrayList(u8).init(allocator);
defer buffer.deinit();

while (true) {
    // read a line from stdin into `line`...
    try buffer.appendSlice(line);
    try buffer.appendSlice("\n");

    if (!try z.checkChunk(buffer.items)) {
        // incomplete, keep reading
        continue;
    }

    try z.exec(buffer.items);
    buffer.clearRetainingCapacity();
}
```

For expression-style results (where `= 1 + 2` should print `3`), use `canLoadAsExpression` to detect whether the input is a valid expression before executing. `loadChunk` and `callLoadedChunk` let you load code once and execute it multiple times, or inspect return values from the stack directly.
