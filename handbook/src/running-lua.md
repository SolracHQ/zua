# Running Lua Code

Zua gives you fine-grained control over executing Lua code. Whether you're running inline snippets, loading files, or building an interactive REPL, the patterns are straightforward.

## Executing for side effects

Use `exec` to run Lua code when you don't need return values:

```zig
try z.exec("print('hello world')");
```

The Lua code runs immediately. Any errors are returned as Zig errors:

```zig
z.exec("bad lua here") catch |err| {
    std.debug.print("Lua error: {}\n", .{err});
};
```

## Evaluating with typed return values

Use `eval` when you need to decode Lua return values into typed Zig data:

```zig
const result = try z.eval(i32, "return 1 + 2");
std.debug.print("1 + 2 = {d}\n", .{result});  // prints: 1 + 2 = 3
```

Eval accepts a comptime tuple type to match the Lua return statement:

```zig
const name = try z.eval([]const u8, "return 'alice'");
const data = try z.eval(.{ []const u8, i32 }, "return 'bob', 42");

std.debug.print("{s} is {d} years old\n", .{ data[0], data[1] });
```

If the Lua code returns the wrong number or types of values, eval fails:

```zig
// Lua returns 1 value, but you asked for 2 values
try z.eval(.{ i32, i32 }, "return 42");  // Error!
```

## Loading and executing files

For larger scripts, use file-based execution:

```zig
// Execute a file for side effects
try z.execFile("init.lua");

// Evaluate a file and get typed results
const config = try z.evalFile(.{ []const u8, i32 }, "config.lua");
```

The file path is relative to the current working directory.

## Error handling with traceback

When Lua code fails, you may want a stack trace. Use `execTraceback` to get error details including traceback information.

`execTraceback` returns a `TraceBackResult` union with the error type and message:

```zig
const result = try z.execTraceback("bad code here");
switch (result) {
    .Ok => std.debug.print("Success\n", .{}),
    .Runtime => |msg| std.debug.print("Runtime error:\n{s}\n", .{msg}),
    .Syntax => |msg| std.debug.print("Syntax error:\n{s}\n", .{msg}),
    .OutOfMemory => |msg| std.debug.print("Out of memory:\n{s}\n", .{msg}),
    .MessageHandler => |msg| std.debug.print("Handler error:\n{s}\n", .{msg}),
    .File => |msg| std.debug.print("File error:\n{s}\n", .{msg}),
    .Unknown => |msg| std.debug.print("Unknown error:\n{s}\n", .{msg}),
}
defer z.freeTraceBackResult(result);
```

The message includes the full stack traceback with line information. Remember to call `freeTraceBackResult` to clean up the allocated message.

## Building a REPL

For interactive input, the library provides low-level helpers to detect and load incomplete chunks.

The key is `checkChunk`: it tells you whether a piece of Lua text is syntactically complete or waiting for more input:

```zig
const chunk = "local x = 1\nprint(x)";
const is_complete = try z.checkChunk(chunk);
```

You can use this to build a line-by-line REPL:

```zig
var buffer = std.ArrayList(u8).init(allocator);
defer buffer.deinit();

while (true) {
    std.debug.print("> ", .{});
    // Read a line from stdin...
    
    try buffer.appendSlice(line);
    try buffer.appendSlice("\n");
    
    if (!(try z.checkChunk(buffer.items))) {
        // Incomplete, keep reading
        std.debug.print(">> ", .{});
        continue;
    }
    
    // Complete chunk, execute it
    try z.exec(buffer.items);
    buffer.clearRetainingCapacity();
}
```

For more sophisticated REPL features, Zua also provides:

- `canLoadAsExpression`: Determines if a chunk is a valid expression (useful for showing eval results)
- `loadChunk`: Loads Lua source without executing it
- `callLoadedChunk`: Executes a previously loaded chunk

For more sophisticated REPL features, Zua provides lower-level building blocks:

```zig
// Check if source is a valid expression
if (try z.canLoadAsExpression("1 + 2")) {
    std.debug.print("It's an expression\n", .{});
}

// Load a chunk without executing
try z.loadChunk("local x = 10; return x * 2");

// Execute the loaded chunk and get results
try z.callLoadedChunk(1);  // Request 1 return value

// Pop the result from the stack
const result = try globals.get(-1, i32);
std.debug.print("Result: {d}\n", .{result});
```

These are useful if you want expression-style results (`= 1 + 2` prints `3`) mixed with statements, or if you need to load code once and execute it multiple times.

## Mixing Zig and Lua

Lua functions call Zig code (via registered callbacks), and Zig code calls back into Lua. This creates a tight feedback loop:

```zig
// Register a Zig function
globals.setFn("double", ZuaFn.pure(doubleValue, .{ .parse_error = "" }));

// Call it from Zig
const result = try z.eval(i32, "return double(21)");
std.debug.print("{d}\n", .{result});  // prints: 42

// That Zig function can then call Lua:
fn doubleValue(value: i32) Result(i32) {
    return Result(i32).ok(value * 2);
}
```

Because Lua code runs synchronously, errors in callbacks propagate naturally as Zig errors.
