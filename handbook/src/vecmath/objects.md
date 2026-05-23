# Objects

At this point you have a complete vector library. You can create vectors, operate on them, lerp between them, and apply transforms. Everything works. But if you stop and think about it, is this really faster than writing the same thing in pure Lua?

Honestly, not by much. Every operation has to decode the input tables into Zig structs, do the math, then encode the result back into a new Lua table. That is a lot of table creation and field hashing just to add two vectors. The only real gain is the lexing, parsing, and compiling time for the math itself, but the overhead of pushing data back and forth eats most of that advantage.

To get real performance we need to skip the table encoding and decoding entirely. That is what Objects are for.

## What is an Object

An Object is zua's name for what Lua calls heavy userdata. The rename felt necessary because "userdata" is not exactly descriptive from a user's perspective, but under the hood they are the same thing.

An Object is a Zig value allocated directly in Lua memory. It lives as long as something in Lua references it. When Lua's garbage collector determines it is no longer reachable, it runs `__gc` and frees the memory. The data is opaque to Lua, which sounds like a disadvantage, but it plays in our favor. Instead of fields scattered as individual Lua table entries with hashing and reference counting overhead, the entire struct sits in a packed, cache-friendly block of memory.

## Changing Table to Object

The change is almost insultingly simple. Take Vec2:

```zig
pub const ZUA_SHAPE = zua.Shape.Table(Vec2, .{ ... }, .{
    .name = "Vec2",
    .description = "A 2D vector with component-wise operations.",
    .field_descriptions = .{ .x = "X component.", .y = "Y component." },
});
```

Change `Table` to `Object` and drop `field_descriptions`, Object options only take `name` and `description`:

```zig
pub const ZUA_SHAPE = zua.Shape.Object(Vec2, .{ ... }, .{
    .name = "Vec2",
    .description = "A 2D vector with component-wise operations.",
});
```

Same for Vec3. Build and test it. Methods and operators still work. But `a.x` and `a.y` will not. The struct is now opaque memory from Lua's perspective, so there are no fields to look up.

## Making fields accessible

zua provides `Modifier.Field` to generate `__index` and `__newindex` entries for specific fields automatically. Change the field declarations from plain types:

```zig
x: f64,
y: f64,
```

to field modifiers:

```zig
x: zua.Shape.Modifier.Field(f64, .{ .description = "X component." }),
y: zua.Shape.Modifier.Field(f64, .{ .description = "Y component." }),
```

Now `a.x` and `a.y = 5` work again. `Modifier.Field(f64, ...)` wraps the `f64` in a thin struct with a single `.value` field. Your Zig code reads and writes through `.value`. Lua reads and writes through the generated `__index` and `__newindex`. From either side it is the same `f64` sitting in memory, there is no conversion.

## Updating the method signatures

With `Table` strategy, methods received `Vec2` by value because zua decoded the table into a fresh struct copy on every call. With `Object` strategy, the data already lives in Lua memory. zua can hand you a pointer directly.

Start with `Vec2` by value and it works:

```zig
fn add(self: Vec2, other: Vec2) Vec2 {
    return .{ .x = .new(self.x.value + other.x.value), .y = .new(self.y.value + other.y.value) };
}
```

But each call copies the entire struct out of the userdata and into a local. For a two-field struct that is cheap, but it adds up in a hot loop. Switch to a pointer and the copy disappears:

```zig
fn add(self: *Vec2, other: *Vec2) Vec2 {
    return .{ .x = .new(self.x.value + other.x.value), .y = .new(self.y.value + other.y.value) };
}
```

Now `self` and `other` point directly into the Lua userdata memory. No copy. But there is a problem. A `*Vec2` lets you write through the pointer, and none of these functions actually modify their inputs. Leaving the pointer mutable means you might accidentally mutate a vector that Lua still holds a reference to, which produces the kind of bug that is very hard to track down.

Mark them `*const` and the compiler closes that door entirely:

```zig
fn add(self: *const Vec2, other: *const Vec2) Vec2 {
    return .{ .x = .new(self.x.value + other.x.value), .y = .new(self.y.value + other.y.value) };
}
```

`*const` tells the compiler these pointers will never be written through. Beyond preventing the accidental mutation, it also allows the compiler to add optimizations it could not apply to a mutable pointer, since it now knows the memory behind them cannot change during the call.

Apply the same pattern to all Vec2 and Vec3 methods, and to the module-level functions that take vectors:

```zig
fn lerp_fn(a: *const Vec2, b: *const Vec2, t: f64) Vec2 {
    return .{
        .x = .new(a.x.value + (b.x.value - a.x.value) * t),
        .y = .new(a.y.value + (b.y.value - a.y.value) * t),
    };
}

fn apply_fn(t: Transform, v: *const Vec2) Vec2 {
    return .{
        .x = .new(t[0][0] * v.x.value + t[0][1] * v.y.value + t[0][2]),
        .y = .new(t[1][0] * v.x.value + t[1][1] * v.y.value + t[1][2]),
    };
}
```

> [!NOTE]
> If you want a field the Lua user can read but not write, use `Modifier.Value` instead of `Modifier.Field`. Only `__index` is generated, and any write attempt from Lua will error with a clear message.

## Performance

Now the library is genuinely faster than a pure Lua version. The critical path, vector addition, dot product, lerp, transforms, operates directly on packed struct memory without creating or destroying any Lua tables. The only allocation per operation is the new userdata returned as the result, and that is managed by Lua's own allocator.

The general rule is: the more data you push through the Lua table boundary, the slower your library becomes. Move critical data and heavy operations to Zig. Expose only what the Lua user needs to read or write through `Field` and `Value`. Every chunk of work that stays on the Zig side is a chunk that does not pay the encoding and decoding tax.

Thanks for coming this far. Have a great time using zua :3
