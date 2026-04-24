# Table and Function handles

`zua.Table` and `zua.Function` are handles to live Lua values. This chapter covers receiving them as parameters, building and reading tables from Zig, and calling Lua functions from Zig.

## zua.Table as a parameter

Declare `zua.Table` as a parameter when you want a live handle to the caller's table rather than a decoded snapshot:

```zig
fn sumValues(ctx: *zua.Context, t: zua.Table) !f64 {
    var total: f64 = 0;
    var i: i32 = 1;
    while (t.has(i)) : (i += 1) {
        total += try t.get(ctx, i, f64);
    }
    return total;
}
```

```lua
print(sumValues({ 1.5, 2.5, 3.0 }))  -- 7
```

`t` is a borrowed handle here. It is valid for the duration of the call.

## Reading and writing table fields

`Table.get` decodes a field by key and returns an error if the key is missing or the type does not match. `Table.has` checks existence without decoding:

```zig
if (t.has("name")) {
    const name = try t.get(ctx, "name", []const u8);
    std.debug.print("name: {s}\n", .{name});
}
```

Keys can be strings or integers:

```zig
const first = try t.get(ctx, 1, i32);   // integer key (array index)
const label = try t.get(ctx, "label", []const u8);  // string key
```

`Table.set` writes a field. It accepts any type that zua knows how to encode:

```zig
try t.set(ctx, "result", 42);
try t.set(ctx, "status", "ok");
```

## zua.Function as a parameter

Declare `zua.Function` as a parameter to receive a Lua function and call it from Zig:

```zig
fn applyTwice(ctx: *zua.Context, cb: zua.Function, value: i32) !i32 {
    const r1 = try cb.call(ctx, .{value}, i32);
    const r2 = try cb.call(ctx, .{r1},    i32);
    return r2;
}
```

```lua
print(applyTwice(function(x) return x * 2 end, 5))  -- 20
```

`cb.call` takes three arguments: the context, a tuple of arguments, and the expected return type. For multiple return values, pass a tuple type:

```zig
const pair = try cb.call(ctx, .{input}, struct { []const u8, i32 });
```

> [!NOTE]
> Raw Zig function signatures cannot be decoded from Lua directly. Use `zua.Function` or the typed wrapper `zua.Fn(ins, outs)` when accepting callbacks from Lua.
>
> You can also construct a callable Lua function handle from a native Zig callback using `zua.Function.create(state, callback)`. For typed wrappers, `zua.Fn(ins, outs).create(&ctx, callback)` builds the typed wrapper and checks the callback signature at compile time.
>
## Storing a Function for later

A `zua.Function` received as a parameter is borrowed and valid only during the current call. To store it and call it later, take ownership:

```zig
var stored: ?zua.Function = null;

fn setCallback(_: *zua.Context, cb: zua.Function) void {
    if (stored) |old| old.release();
    stored = cb.takeOwnership();
}

fn invokeStored(ctx: *zua.Context, value: i32) !i32 {
    const cb = stored orelse return ctx.fail("no callback stored");
    return try cb.call(ctx, .{value}, i32);
}

fn clearCallback() void {
    if (stored) |cb| {
        cb.release();
        stored = null;
    }
}
```

## zua.Fn: typed function wrappers

`zua.Fn(ins, outs)` is a typed wrapper over `zua.Function` that encodes the expected argument and return types. Use it when you want static type safety on the call signature or when storing a callback in a Zig struct field:

```zig
const Handler = struct {
    pub const ZUA_META = zua.Meta.Object(Handler, .{
        .set = setCallback,
        .run = runCallback,
        .__gc = cleanup,
    });

    cb: ?zua.Fn(i32, i32) = null,

    pub fn setCallback(self: *Handler, cb: zua.Fn(i32, i32)) void {
        if (self.cb) |old| old.release();
        self.cb = cb.takeOwnership();
    }

    pub fn runCallback(ctx: *zua.Context, self: *Handler, value: i32) !i32 {
        const cb = self.cb orelse return ctx.fail("no callback set");
        return try cb.call(ctx, .{value});
    }

    pub fn cleanup(self: *Handler) void {
        if (self.cb) |cb| cb.release();
    }
};
```

`zua.Fn` values are decoded from Lua functions, participate in the same ownership model as `zua.Function`, and must be released in `__gc` if they are stored on an object.
