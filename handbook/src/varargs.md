# VarArgs and Primitive

Sometimes you want a function that accepts any number of Lua arguments without fixing the arity upfront. Declare `zua.VarArgs` as the **last** parameter and zua collects every remaining Lua argument into a `[]Primitive` slice allocated from the context arena.

## Basic usage

```zig
fn sumAll(ctx: *zua.Context, args: zua.VarArgs) !i64 {
    var total: i64 = 0;
    for (args.args) |prim| {
        switch (prim) {
            .integer => |i| total += i,
            .float   => |f| total += @intFromFloat(f),
            else     => return ctx.fail("sum_all expects numbers"),
        }
    }
    return total;
}
```

```lua
print(sum_all(1, 2, 3, 4, 5))  -- 15
print(sum_all())                -- 0
```

Fixed parameters before `VarArgs` are decoded normally. `VarArgs` receives whatever is left:

```zig
fn log(prefix: []const u8, rest: zua.VarArgs) void {
    for (rest.args) |arg| {
        std.debug.print("{s}: {s}\n", .{ prefix, @tagName(arg) });
    }
}
```

```lua
log("type", 1, true, "hello", 3.14)
-- type: integer
-- type: boolean
-- type: string
-- type: float
```

> [!NOTE]
> `VarArgs` must be the last parameter of the function. Placing it anywhere else is a compile error.

## The Primitive union

Each element of `args.args` is a `Primitive`, the same union used by custom decode hooks. Its variants map directly to Lua types:

| Variant | Lua type |
|---|---|
| `.nil` | nil or absent |
| `.boolean` | boolean |
| `.integer` | integer |
| `.float` | float |
| `.string` | string |
| `.table` | table (borrowed) |
| `.function` | function (borrowed) |
| `.light_userdata` | light userdata |
| `.userdata` | full userdata (borrowed) |

`table`, `function`, and `userdata` variants hold borrowed handles valid only during the current callback. Call `.takeOwnership()` before returning if you need them to outlive the call.

## decodeValue

`zua.decodeValue(ctx, prim, T)` converts any `Primitive` into a typed Zig value using the same dispatch as the standard decoder, including optional handling for `.nil`:

```zig
fn firstOrDefault(ctx: *zua.Context, args: zua.VarArgs) !i32 {
    if (args.args.len == 0) return 0;
    return zua.decodeValue(ctx, args.args[0], i32);
}
```

This is useful when you want to handle some arguments generically and decode others with full type checking.

## Describing argument types

A common use for `VarArgs` is logging or debugging functions that accept anything:

```zig
fn describeArgs(ctx: *zua.Context, args: zua.VarArgs) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    for (args.args, 0..) |prim, i| {
        if (i > 0) try buf.appendSlice(ctx.allocator(), ", ");
        try buf.appendSlice(ctx.allocator(), @tagName(prim));
    }
    return buf.items;
}
```

```lua
print(describeArgs(1, true, "hello", 3.14))  -- integer, boolean, string, float
```
