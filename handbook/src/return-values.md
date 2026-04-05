# Return Values

All callbacks return a `Result`. The type parameter declares what gets pushed back to Lua.

## Single value

```zig
fn nextId(_: *Zua) Result(i32) {
    return Result(i32).ok(42);
}
```

## Multiple values

```zig
fn minmax(_: *Zua, a: f64, b: f64) Result(.{ f64, f64 }) {
    return Result(.{ f64, f64 }).ok(.{ @min(a, b), @max(a, b) });
}
```

## No return value

```zig
fn logMessage(_: *Zua, msg: []const u8) Result(.{}) {
    std.log.info("{s}", .{msg});
    return Result(.{}).ok(.{});
}
```

## Allocated strings

For ordinary values `ok` is enough. When the success value is an allocated string, use `owned`. The trampoline clones and frees the string after pushing it, so you do not track the allocation yourself.

```zig
fn format(z: *Zua, value: i32) Result([]const u8) {
    const text = std.fmt.allocPrint(z.allocator, "value={d}", .{value}) catch return Result([]const u8).errStatic("out of memory");
    return Result([]const u8).owned(z.allocator, text);
}
```

## Failures

Three constructors cover the common failure cases:

```zig
return Result(i32).errStatic("missing pid");
return Result(i32).errOwned(z.allocator, "pid {d} out of range", .{pid});
return Result(i32).errZig(err);
```

`errStatic` takes a string literal. `errOwned` formats and allocates a message, freed by the trampoline before raising the Lua error. `errZig` surfaces a Zig error value by name.

On any failure, zua raises a Lua error after your function has fully returned. Zig `defer` blocks run normally.