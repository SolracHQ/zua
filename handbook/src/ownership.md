# Handles and ownership

zua uses handles to represent Lua values on the Zig side. A handle is a thin wrapper around a Lua stack slot or registry reference. Every handle has an ownership mode, and getting the mode wrong leads to either dangling references or memory leaks.

## The three ownership modes

**Borrowed** handles point to a Lua stack slot owned by the current call frame. They are valid only for the duration of the current callback. You cannot call `.release()` on a borrowed handle because you do not own it.

**Stack-owned** handles own a Lua value on the current stack. They remain valid until `.release()` removes the value. `Table.create()` and `z.globals()` return stack-owned handles.

**Registry-owned** handles own a Lua registry reference. They survive after the current callback returns and across callback invocations. They must be released explicitly with `.release()`.

> [!NOTE]
> The Lua registry is a special table inside the Lua state that is not accessible from Lua code. Storing a value there anchors it so the garbage collector cannot collect it, regardless of whether Lua code still holds a reference to it.

You can tell which mode a handle is in by how you got it:
- came from a function parameter: **borrowed**,
- came from `Table.create()`, `globals()`, or similar factory: **stack-owned**,
- came from calling `.takeOwnership()`: **registry-owned**.

## takeOwnership and release

Call `.takeOwnership()` on any handle to move it into the Lua registry and release the original stack-owned reference when applicable. The returned handle is registry-owned and survives until you call `.release()`:

```zig
var stored: ?zua.Function = null;

fn setCallback(_: *zua.Context, cb: zua.Function) void {
    if (stored) |old| old.release();
    stored = cb.takeOwnership();
}

fn clearCallback() void {
    if (stored) |cb| {
        cb.release();
        stored = null;
    }
}
```

If you need a second registry-owned copy without releasing the original handle, use `.owned()` instead.

> [!IMPORTANT]
> Registry-owned handles must be released with `.release()` when you no longer need them. Failing to release leaks the Lua reference and prevents the garbage collector from collecting the function or table.

## Stack-owned handles

Stack-owned handles must be released before the enclosing scope returns. The standard pattern is `defer`:

```zig
const globals = z.globals();
defer globals.release();

try globals.set(&ctx, "add", add);
// release() happens here, at end of scope
```

If you return a stack-owned handle from a callback, the trampoline takes ownership and you do not call `.release()` yourself:

```zig
fn makeTable(ctx: *zua.Context) !zua.Table {
    const t = Table.create(z, 0, 2);
    try t.set(ctx, "x", 1);
    try t.set(ctx, "y", 2);
    return t;  // trampoline takes ownership, do not release
}
```

## Borrowed handles inside callbacks

When a `zua.Function` or `zua.Table` arrives as a function parameter, it is borrowed. Use it directly if you only need it during the call. If you need it later, take ownership:

```zig
fn processTable(ctx: *zua.Context, t: zua.Table) !i32 {
    // t is borrowed, valid only during this call
    return try t.get(ctx, "value", i32);
}

fn storeTable(_: *zua.Context, t: zua.Table) void {
    // takeOwnership moves t to the registry so it outlives this call
    stored_table = t.takeOwnership();
}
```

## Handle types

The handle types in zua are:

| Type | Wraps | Notes |
|---|---|---|
| `zua.Table` | Lua table | stack or registry owned |
| `zua.Function` | Lua function | stack or registry owned |
| `zua.Userdata` | Lua full userdata | raw untyped handle |
| `zua.Object(T)` | Lua full userdata | typed wrapper over `Userdata`, `.get()` returns `*T` |
| `zua.Fn(ins, outs)` | Lua function | typed wrapper over `Function` |
| `zua.TableView(T)` | Lua table | typed mirror with sync back to Lua |

`zua.Object(T)` and `zua.Fn(ins, outs)` are covered in their own chapters. The ownership rules are the same for all handle types: borrowed parameters are valid only during the call, and registry-owned handles must be released.
