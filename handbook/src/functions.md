# Functions

The core idea is that Lua-callable functions are just Zig functions. You declare typed parameters, zua decodes the Lua arguments into them, and you return a `Result`.

## Defining a function

```zig
fn add(a: i32, b: i32) Result(i32) {
    return Result(i32).ok(a + b);
}
```

Parameters are decoded from the Lua argument list in order, left to right. The types drive the decoding. If a Lua caller passes the wrong type or the wrong number of arguments, zua raises a Lua error with the message you provide at registration.

## Registering a function

Use `ZuaFn.pure` for functions that do not need access to the VM:

```zig
globals.setFn("add", ZuaFn.pure(add, "add expects (i32, i32)"));
```

Use `ZuaFn.from` for functions that need the VM, for example to access the allocator or the registry. The first parameter must be `*Zua`:

```zig
fn greet(z: *Zua, name: []const u8) Result([]const u8) {
    const msg = std.fmt.allocPrint(z.allocator, "hello, {s}", .{name}) catch return Result([]const u8).errStatic("out of memory");
    return Result([]const u8).owned(z.allocator, msg);
}

globals.setFn("greet", ZuaFn.from(greet, "greet expects (string)"));
```

## Optional parameters

Declare optional parameters as `?T`. Missing trailing arguments and explicit Lua `nil` both decode as `null`.

```zig
fn add(a: i32, b: ?i32) Result(i32) {
    return Result(i32).ok(a + (b orelse 0));
}
```

## Error union callbacks

Callbacks may return `!Result(T)`. Zig errors are converted to Lua-facing failures automatically by the trampoline.

```zig
fn readFile(z: *Zua, path: []const u8) !Result([]const u8) {
    const contents = try std.fs.cwd().readFileAlloc(z.allocator, path, 1024 * 1024);
    return Result([]const u8).owned(z.allocator, contents);
}
```

## Supported parameter types

`i32`, `i64`, `f32`, `f64`, `[]const u8`, `[:0]const u8`, `bool`, nested structs, and `?T` for any of the above.