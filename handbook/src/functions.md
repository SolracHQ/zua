# Functions

The core idea is simple: a Zig function is a Lua-callable function. You declare typed parameters, zua decodes the Lua arguments into them, and you return a `Result`.

## Your first function

```zig
fn add(a: i32, b: i32) Result(i32) {
    return Result(i32).ok(a + b);
}
```

To register it, decide whether the function needs access to the Zua instance. If not, use `ZuaFn.pure`:

```zig
globals.setFn("add", ZuaFn.pure(add, .{
    .parse_err_fmt = "add expects (i32, i32)",
}));
```

If it does, use `ZuaFn.from` and add `*Zua` as the first parameter:

```zig
fn greet(z: *Zua, name: []const u8) Result([]const u8) {
    const msg = std.fmt.allocPrint(z.allocator, "hello, {s}", .{name})
        catch return Result([]const u8).errStatic("out of memory");
    return Result([]const u8).owned(msg);
}

globals.setFn("greet", ZuaFn.from(greet, .{
    .parse_err_fmt = "greet expects (string)",
}));
```

The `parse_err_fmt` string is what Lua sees if the arguments do not match. Use `{s}` as a placeholder for the decode error message from custom decode hooks:

```zig
globals.setFn("api_call", ZuaFn.from(apiCall, .{
    .parse_err_fmt = "api_call failed: {s}",
}));
```

### Custom error messages from decode hooks

For complex argument validation, provide a custom `parse_err_hook` that receives the actual Lua type that failed to decode:

```zig
fn parseErrHook(z: *Zua, actual_type: zua.lua.Type, index: zua.lua.StackIndex, error_message: []const u8) []const u8 {
    return std.fmt.allocPrint(z.allocator, "expected i32 at position {d}, got {s}: {s}", .{
        index, @tagName(actual_type), error_message,
    }) catch z.allocator.dupe(u8, "out of memory") catch "out of memory";
}

globals.setFn("strictAdd", ZuaFn.from(add, .{
    .parse_err_hook = parseErrHook,
    .parse_err_fmt = "add expects two integers: {s}",  // fallback
}));
```

The hook receives the decoded value's type, the stack position where decode failed, and any error message from custom decode logic. The hook should return an allocator-owned string; the trampoline frees it after raising the error.

## Return values

`Result(T)` wraps your return type. For a single value, `ok` is all you need:

```zig
fn answer(_: *Zua) Result(i32) {
    return Result(i32).ok(42);
}
```

For multiple return values, use an anonymous tuple:

```zig
fn minmax(_: *Zua, a: f64, b: f64) Result(.{ f64, f64 }) {
    return Result(.{ f64, f64 }).ok(.{ @min(a, b), @max(a, b) });
}
```

For no return value:

```zig
fn log(_: *Zua, msg: []const u8) Result(.{}) {
    std.log.info("{s}", .{msg});
    return Result(.{}).ok(.{});
}
```

### Allocated strings

When you allocate a string to return, use `owned` instead of `ok`. The trampoline takes ownership and frees it after pushing to Lua:

```zig
fn format(z: *Zua, value: i32) Result([]const u8) {
    const text = std.fmt.allocPrint(z.allocator, "value={d}", .{value})
        catch return Result([]const u8).errStatic("out of memory");
    return Result([]const u8).owned(text);
}
```

Always allocate with `z.allocator`. The trampoline frees with the same allocator, so mixing allocators will go wrong.

## Errors

Three constructors cover the common cases:

```zig
return Result(i32).errStatic("missing pid");
return Result(i32).errOwned(z.allocator, "pid {d} out of range", .{pid});
return try err;
```

`errStatic` takes a string literal. `errOwned` formats a message on the allocator and frees it before raising the Lua error. `errOwnedString` takes a pre-allocated string. Zig errors also propagate through `!Result(T)` and automatically become Lua errors.

Errors always raise a Lua error after your function returns. Zig `defer` blocks run normally, which is the main reason zua uses this pattern instead of calling `lua_error` directly from inside the callback.

Callbacks can also return `!Result(T)`. Zig errors propagate through the trampoline and become Lua errors automatically:

```zig
fn readFile(z: *Zua, path: []const u8) !Result([]const u8) {
    const contents = try std.fs.cwd().readFileAlloc(z.allocator, path, 1024 * 1024);
    return Result([]const u8).owned(contents);
}
```

## Configuring error messages

The second argument to `ZuaFn.pure` and `ZuaFn.from` is a `ZuaFnErrorConfig`. You can pass an anonymous struct literal for convenience, but the full type gives you three fields:

```zig
globals.setFn("read_file", ZuaFn.from(readFile, ZuaFnErrorConfig{
    .parse_err_fmt = "read_file expects (string)",
    .zig_err_fmt = "read_file failed: {s}",
    .zig_err_hook = null,
}));
```

`parse_err_fmt` is what Lua sees when argument decoding fails. It receives the decode error message as `{s}`. `zig_err_fmt` is a format string that receives the Zig error name as `{s}`. If you need to produce a more descriptive message at runtime, use `zig_err_hook` instead:

```zig
fn describeError(z: *Zua, err: anyerror) []const u8 {
    return std.fmt.allocPrint(z.allocator, "file error ({s}): check path and permissions", .{
        @errorName(err),
    }) catch "file error";
}

globals.setFn("read_file", ZuaFn.from(readFile, ZuaFnErrorConfig{
    .parse_err_fmt = "read_file expects (string)",
    .zig_err_hook = describeError,
}));
```

The hook takes precedence over `zig_err_fmt` when both are set. The returned string must be allocated with `z.allocator`. zua frees it after raising the Lua error.

## Optional parameters

Declare optional parameters as `?T`. A missing trailing argument or an explicit `nil` both decode as `null`:

```zig
fn add(a: i32, b: ?i32) Result(i32) {
    return Result(i32).ok(a + (b orelse 0));
}
```

Lua can call this as `add(1)` or `add(1, nil)` and both work.

## Receiving Lua functions

Just as Lua can call Zig functions, Zig can receive and call Lua functions. Declare a parameter of type `Function(types)` where `types` is the tuple of return types:

```zig
fn applyTwice(z: *Zua, callback: Function(i32), value: i32) Result(i32) {
    // callback is a borrowed Lua function that returns i32
    const result1 = try callback.call(z, .{value});
    const result2 = try callback.call(z, .{result1});
    return Result(i32).ok(result2);
}
```

```lua
function double(x)
    return x * 2
end

applyTwice(double, 5)  -- double(double(5)) = 20
```

### Multiple return values

Callbacks can return multiple values:

```zig
fn swapAndProcess(z: *Zua, callback: Function(.{ []const u8, i32 }), input: i32) Result([]const u8) {
    const result = try callback.call(z, .{input});
    // result is a tuple: .{ []const u8, i32 }
    const message = result[0];
    const code = result[1];
    
    std.debug.print("{s} (code {d})\n", .{ message, code });
    return Result([]const u8).ok(message);
}
```

### Storing callbacks for later

Callbacks received as parameters are borrowed — valid only during the callback invocation. To store a callback for later use, call `.takeOwnership()`:

```zig
var stored_callback: ?zua.OwnedFunction(.{i32}) = null;

fn setCallback(z: *Zua, cb: Function(.{i32})) Result(.{}) {
    stored_callback = try cb.takeOwnership();
    return Result(.{}).ok(.{});
}

fn invokeStored(z: *Zua, value: i32) Result(i32) {
    if (stored_callback) |callback| {
        const result = try callback.call(z, .{value});
        return Result(i32).ok(result);
    }
    return Result(i32).errStatic("no callback stored");
}

fn clearCallback() void {
    if (stored_callback) |callback| {
        callback.release();
        stored_callback = null;
    }
}
```

Registry-owned callbacks (from `.takeOwnership()`) must be explicitly released. Call `.release()` to free the registry reference, typically during shutdown or when the callback is no longer needed.

### Error handling

Function calls can fail due to Lua runtime errors or decode failures. Errors are returned in the `Result` wrapper:

```zig
fn safeCall(z: *Zua, callback: Function(i32)) Result(i32) {
    const result = try callback.call(z, .{}) catch |err| {
        // Lua runtime or allocation error
        return Result(i32).errStatic("callback failed");
    };
    
    if (result.failure) |failure| {
        // Decode error from hook or type mismatch
        const msg = switch (failure) {
            .static_message => |m| m,
            .owned_message => |m| m,
        };
        return Result(i32).errOwned(z, "callback returned wrong type: {s}", .{msg});
    }
    
    return Result(i32).ok(result.values);
}
```

## Supported parameter types

`i32`, `i64`, `f32`, `f64`, `bool`, `[]const u8`, `[:0]const u8`, structs, `Function` (for callbacks), and `?T` for any of the above. Tables and userdata are covered in later chapters.
