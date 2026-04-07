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
    .parse_err_fmt = "entry:get takes no arguments",
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

`eval` decodes Lua return values and returns a `Result` to preserve any error messages from custom decode hooks:

```zig
const result = try z.eval(i32, "return 1 + 2");
const num = result.unwrap();  // panics if decode fails

const data_result = try z.eval(.{ []const u8, i32 }, "return 'bob', 42");
if (data_result.failure) |failure| {
    const err_msg = switch (failure) {
        .static_message => |msg| msg,
        .owned_message => |msg| msg,
    };
    // handle error...
} else {
    const data = data_result.values;
    std.debug.print("{s} is {d}\n", .{ data[0], data[1] });
}
```

The `Result` carries any custom error messages from decode hooks, allowing you to distinguish between a type mismatch and a failed validation rule inside the hook.

## Files

```zig
try z.execFile("init.lua");

const config_result = try z.evalFile(.{ []const u8, i32 }, "config.lua");
const config = config_result.unwrap();  // or check .failure field
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
