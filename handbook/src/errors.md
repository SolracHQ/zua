# Errors

zua gives you a clean way to report errors to Lua without ever calling `lua_error` directly. This matters because `lua_error` uses `longjmp` internally, which unwinds the C call stack non-locally and skips any `defer` statements between the call site and the `setjmp` handler. zua defers the actual error raise until after your Zig function has fully returned, so `defer` is always safe to use inside your callbacks.

## ctx.fail and ctx.failWithFmt

Functions that can fail should return `!T`. Use `ctx.fail` to raise a static error message:

```zig
fn divide(ctx: *zua.Context, a: f64, b: f64) !f64 {
    if (b == 0) return ctx.fail("division by zero");
    return a / b;
}
```

```lua
local ok, err = pcall(divide, 10, 0)
print(err)  -- division by zero
```

For a message built at runtime, use `ctx.failWithFmt`:

```zig
fn openFile(ctx: *zua.Context, path: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(ctx.arena(), path, 1024 * 1024)
        catch |err| return ctx.failWithFmt("cannot open '{s}': {s}", .{ path, @errorName(err) });
}
```

Both functions return an error value you propagate with `return`. They do not raise the Lua error immediately. The trampoline raises it after your function has returned cleanly, which is why `defer` works correctly.

## Zig errors reaching the trampoline

If a Zig error escapes your function without being caught, the trampoline catches it and converts it to a Lua error. Use `zig_err_fmt` in `ZuaFn.new` to control the message:

```zig
fn readFile(ctx: *zua.Context, path: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(ctx.arena(), path, 1024 * 1024);
}

globals.set(&ctx, "read_file", zua.ZuaFn.new(readFile, .{
    .parse_err_fmt = "read_file expects (string): {s}",
    .zig_err_fmt   = "read_file failed: {s}",
}));
```

The `{s}` in `zig_err_fmt` is filled with the Zig error name, for example `FileNotFound`.

When you need to build the error message dynamically based on which error occurred, use `zig_err_hook`:

```zig
fn describeError(ctx: *zua.Context, err: anyerror) void {
    ctx.err = std.fmt.allocPrint(
        ctx.arena(),
        "file error ({s}): check path and permissions",
        .{@errorName(err)},
    ) catch "file error";
}

globals.set(&ctx, "read_file", zua.ZuaFn.new(readFile, .{
    .parse_err_fmt = "read_file expects (string): {s}",
    .zig_err_hook  = describeError,
}));
```

The hook sets `ctx.err`. If it allocates, use `ctx.arena()` so zua owns and frees the string after raising the error.

## Catching errors from Zig

Errors from `executor.execute` and `executor.eval` work like any Zig error. When the call fails, `ctx.err` holds the Lua error message:

```zig
executor.execute(&ctx, .{ .code = .{ .string = "this is not valid lua" } }) catch |err| {
    std.debug.print("lua error: {s}\n", .{ctx.err orelse "unknown"});
};
```

## Stack tracebacks

Set `stack_trace` in the config to get a full traceback alongside the error:

```zig
executor.execute(&ctx, .{
    .code        = .{ .string = "error('boom')" },
    .stack_trace = .owned,
}) catch {
    std.debug.print("error: {s}\n", .{ctx.err orelse "unknown"});
    if (executor.stack_trace) |trace| {
        std.debug.print("traceback:\n{s}\n", .{trace});
        ctx.heap().free(trace);
    }
};
```

`.owned` allocates the traceback from the state allocator, and you are responsible for freeing it. `.on_arena` ties the traceback to the current `Context` and frees it automatically when `ctx.deinit()` runs.
