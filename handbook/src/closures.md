# Closures

Sometimes a function needs private mutable state that persists across calls: a counter, an accumulator, a rate limiter. You could use an object for this, but closures let you express it more directly. The state travels inside the function itself.

## Declaring a capture

Declare a struct with `Meta.Capture` and register it with `ZuaFn.newClosure`:

```zig
const CounterState = struct {
    pub const ZUA_META = zua.Meta.Capture(@This(), .{});
    count: i32,
    step:  i32,
};

fn counterTick(s: *CounterState) i32 {
    s.count += s.step;
    return s.count;
}
```

Then register the closure with an initial value:

```zig
try state.addGlobals(&ctx, .{
    .counter = zua.ZuaFn.newClosure(
        counterTick,
        CounterState{ .count = 0, .step = 1 },
        .{},
    ),
});
```

```lua
print(counter())  -- 1
print(counter())  -- 2
print(counter())  -- 3
```

Each call to `newClosure` allocates a **fresh, independent** capture. Registering the same function twice with different initial values gives two closures that never share state:

```zig
try state.addGlobals(&ctx, .{
    .by_one = zua.ZuaFn.newClosure(counterTick, CounterState{ .count = 0, .step = 1  }, .{}),
    .by_ten = zua.ZuaFn.newClosure(counterTick, CounterState{ .count = 0, .step = 10 }, .{}),
});
```

```lua
print(by_one())  -- 1
print(by_one())  -- 2
print(by_ten())  -- 10
print(by_one())  -- 3  (unaffected by by_ten calls)
```

The capture struct is stored as Lua userdata in upvalue 1 of the C closure. Its lifetime is managed by Lua's garbage collector, exactly like an object created with `Meta.Object`.

## Parameter position

The capture parameter must be a pointer `*T` and must appear in a fixed position:
- first parameter when there is no context,
- second parameter when `*Context` is first.

```zig
fn tick(s: *CounterState) i32 { ... }

fn tickWithCtx(ctx: *zua.Context, s: *CounterState, extra: i32) !i32 { ... }
```

Placing the capture parameter anywhere else is a compile error.

## Cleanup with __gc

If the captured struct owns heap memory or Lua handles, declare `__gc` in the `Meta.Capture` options:

```zig
const BufState = struct {
    pub const ZUA_META = zua.Meta.Capture(@This(), .{
        .__gc = cleanup,
    });
    data:      []u8,
    allocator: std.mem.Allocator,

    fn cleanup(self: *BufState) void {
        self.allocator.free(self.data);
    }
};
```

Lua calls `__gc` when the closure is collected, so the memory is always freed.

## Partial application with captured Lua callbacks

Closures can capture Lua functions, not just plain data. This lets you implement partial application: receive a function and some arguments from Lua, and return a new function that remembers them.

```zig
const PartialState = struct {
    pub const ZUA_META = zua.Meta.Capture(@This(), .{
        .__gc = release,
    });

    f:     zua.Fn(.{i32, i32}, i32),
    first: i32,

    fn release(self: *PartialState) void {
        self.f.release();
    }
};

fn partialCall(ctx: *zua.Context, s: *PartialState, n: i32) !i32 {
    return s.f.call(ctx, .{ s.first, n });
}

fn alwaysWith(
    ctx: *zua.Context,
    first: i32,
    f:    zua.Fn(.{i32, i32}, i32),
) zua.ZuaFn.ZuaFnClosureType(partialCall, .{}) {
    _ = ctx;
    return zua.ZuaFn.newClosure(partialCall, PartialState{
        .f     = f.takeOwnership(),
        .first = first,
    }, .{});
}
```

```lua
local add  = function(a, b) return a + b end
local add5 = alwaysWith(5, add)
print(add5(3))   -- 8
print(add5(10))  -- 15
```

`alwaysWith` receives `first` and `f` from Lua, takes ownership of `f` so it survives past the call, and returns a new closure that bundles both. The `__gc` on `PartialState` releases the owned `Fn` handle when Lua collects the closure. Without it the Lua function would leak in the registry.

> [!NOTE]
> `zua.Fn(ins, outs)` gives static type safety on the call signature. If you do not know the arity ahead of time, `zua.Function` works the same way; call it with `.call(ctx, .{...}, ReturnType)` instead.
