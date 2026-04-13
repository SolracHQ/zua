# First function

The fastest way to understand zua is to register something and call it. This chapter covers functions that take arguments, do work, and return a value, without needing anything from the Lua runtime.

## A plain function

```zig
fn add(a: i32, b: i32) i32 {
    return a + b;
}

globals.set(&ctx, "add", add);
```

```lua
print(add(1, 2))    -- 3
print(add("oops"))  -- error: add expects (i32, i32): got string
```

A raw Zig function reference is automatically wrapped as a Lua callable. `globals.set` generates a trampoline at compile time that decodes Lua arguments, calls your function, and pushes the return value back.

## Controlling the error message

When the caller passes wrong argument types, zua raises a Lua error before your function is ever called. By default the message is generic. Wrap the function in `ZuaFn.new` to control it:

```zig
globals.set(&ctx, "add", zua.ZuaFn.new(add, .{
    .parse_err_fmt = "add expects (i32, i32): {s}",
}));
```

The `{s}` placeholder is filled with the decode failure description, for example `"expected i32, got string"`. `ZuaFn.new` is optional; use it only when the default message is not informative enough.

## Argument types

zua maps Lua value types to Zig types automatically. The supported mappings for function parameters are:

| Zig type | Expected Lua value |
|---|---|
| `i32`, `i64` and other integers | integer |
| `f32`, `f64` | number (integer or float) |
| `bool` | boolean |
| `[]const u8`, `[:0]const u8` | string |
| `?T` | T, or nil or missing |

> [!NOTE]
> In Lua, integers and floats are both called "number". Lua 5.4 introduced an internal distinction, but from the Lua side `1` and `1.0` look similar. zua checks at the boundary: `i32` accepts only integer Lua values, while `f64` accepts both integer and float.

> [!WARNING]
> Unsigned integers wider than `u63` may not round-trip cleanly through Lua numeric values. For values outside that range, use an object handle instead. This is covered in the [Strategies](./strategies.md) chapter.

## Return values

Return any supported type directly:

```zig
fn answer() i32 {
    return 42;
}
```

For multiple return values, use an anonymous struct tuple. Lua receives them as multiple return values in the usual way:

```zig
fn minmax(a: f64, b: f64) struct { f64, f64 } {
    return .{ @min(a, b), @max(a, b) };
}
```

```lua
local lo, hi = minmax(5, 2)
print(lo, hi)  -- 2   5
```

For no return value, return `void`:

```zig
fn logMessage(msg: []const u8) void {
    std.log.info("{s}", .{msg});
}
```

## Optional parameters

Wrap a parameter type in `?` to make it optional. A missing trailing argument or an explicit `nil` from Lua both decode as `null`:

```zig
fn add(a: i32, b: ?i32) i32 {
    return a + (b orelse 0);
}
```

```lua
print(add(5))       -- 5
print(add(5, 3))    -- 8
print(add(5, nil))  -- 5
```

Optional parameters must come after all required parameters.

> [!NOTE]
> Functions that need to allocate memory or report errors to Lua need one more thing: a `*zua.Context` as the first parameter. That is covered in the next chapter.