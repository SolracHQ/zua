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
    .parse_error = "add expects (i32, i32)",
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
    .parse_error = "greet expects (string)",
}));
```

The `parse_error` message is what Lua sees if the arguments do not match. Make it useful.

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
return Result(i32).errZig(err);
```

`errStatic` takes a string literal. `errOwned` formats a message on the allocator and frees it before raising the Lua error. `errZig` surfaces a Zig error value by name.

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
    .parse_error = "read_file expects (string)",
    .zig_err_fmt = "read_file failed: {s}",
    .zig_err_hook = null,
}));
```

`parse_error` is what Lua sees when argument decoding fails. `zig_err_fmt` is a format string that receives the Zig error name as `{s}`. If you need to produce a more descriptive message at runtime, use `zig_err_hook` instead:

```zig
fn describeError(z: *Zua, err: anyerror) []const u8 {
    return std.fmt.allocPrint(z.allocator, "file error ({s}): check path and permissions", .{
        @errorName(err),
    }) catch "file error";
}

globals.setFn("read_file", ZuaFn.from(readFile, ZuaFnErrorConfig{
    .parse_error = "read_file expects (string)",
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

## Supported parameter types

`i32`, `i64`, `f32`, `f64`, `bool`, `[]const u8`, `[:0]const u8`, structs, and `?T` for any of the above. Tables and userdata are covered in later chapters.
