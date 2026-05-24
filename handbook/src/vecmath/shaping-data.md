# Shapes and Context

If you keep playing with what we did so far, you will notice that trying to print our vectors gives something like `table: 0x7f8a4b2040c0`. That is the default behavior for all Lua tables and it is ugly.

Those who come from Lua know what comes next, but since zig is not Lua I need to first explain one of the hearts of the zua library, Shapes.

## What is a Shape?

You might ask, with all the reason in the world. A Shape is the API that zua provides to customize how the encoder "shapes" Zig data into Lua values and how it "shapes" Lua values back into Zig data.

> [!NOTE]
> Shape is maybe not the best name, but it is well known that programmers suck at naming things and I am not the exception.

The declaration is simple, you must define a public constant called `ZUA_SHAPE` on your type. This is required because the data must be available at comptime.

There are several available shapes, each designed for a different usage and different Zig types. For now we will use the most simple one: `Shape.Table`.

Modify `Vec2` like this:

```zig
pub const Vec2 = struct {
    x: f64,
    y: f64,

    pub const ZUA_SHAPE = zua.Shape.Table(Vec2, .{}, .{});
};
```

> [!NOTE]
> For those not familiar with Zig: comptime is one of Zig's biggest strengths. It lets you execute normal Zig code at compilation time. The work happens only once, allowing you to precompute values or choose better paths for certain types, and then use them at runtime without extra effort.

You will notice two empty `.{}` in the `Shape.Table` call. Each one configures different behavior for the type. For now we will leave them with the defaults.

If you run the code now you will notice that nothing changed. That is because the default strategy for Zig structs is already a Lua table. But now that we have the Shape declared, we can start adding what Lua users expect, methods and metamethods.

## Adding `__tostring`

Lua has operator overloading, including string conversion. When Lua needs to convert a table to a string, it looks for a `__tostring` key in the table's metatable and calls it with the table as argument. zua provides a straightforward way to add methods and metamethods.

First we need a function that returns a string representation. Lets start simple, without using the actual vector values:

```zig
fn toString(_: Vec2) []const u8 {
    return "Vec2";
}
```

As you can see it receives a copy of the vector. We ignore it with `_` because we do not use it yet. "Wait, what? That is useless!" you might think. And yes, it is useless. But what can we do? We need an allocator to format a string at runtime. Zig has `std.heap.c_allocator`, `std.heap.page_allocator`, and `std.heap.debug_allocator`, but they will leak because we never free the memory.

> [!NOTE]
> For those who never touched a low level language before: when you allocate memory you are responsible for freeing it. Otherwise you accumulate unused memory until either your program dies (on a good OS) or your computer dies (on a bad OS). Especially now that RAM is so expensive.

That is where the Context we talked about so long comes to rescue us.

## Context and the arena

Every zua function can have `*zua.Context` as its first parameter. Context is our primary tool to communicate the Zig world with the Lua world. It holds the state, but it also holds exactly what we need for our never-free problem, an arena allocator.

> [!NOTE]
> An arena allocator is a special kind of allocator that does not need individual frees. You allocate as much as you want and at the end of the lifetime you free everything in a single call.

The context is an ephemeral value that lives only from function call to result push on the Lua stack. That means you can return arena-allocated types, they survive long enough to be pushed to Lua, and then the arena is released safely.

Context also serves another purpose, failing. Those with experience in the Lua API know `lua_error` and its longjmp. It is a beautiful mechanism for error propagation, but it has a big problem in the Zig context: it skips `defer` statements, and `defer` is the main mechanism in Zig for cleanup. zua solves this with Context. You do not call `lua_error`. You make your return type an error union and return a normal Zig error. The error message is handled the same way: just return `ctx.failTyped(ReturnType, "message")`.

> [!NOTE]
> For those who do not know what longjmp and defer are: `lua_error` uses a C mechanism called longjmp that jumps out of the current function directly to an error handler, skipping any cleanup code in between. Zig's `defer` runs cleanup code when a scope exits normally. If a longjmp skips the scope exit, the deferred code never runs. zua avoids this by not calling `lua_error` directly inside your function. It records the error and raises it after your function returns, so `defer` works correctly.

Knowing this, our `toString` becomes:

```zig
fn toString(ctx: *zua.Context, self: Vec2) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena(), "vec2({d}, {d})", .{ self.x, self.y })
        catch ctx.failTyped([]const u8, "out of memory");
}
```

> [!NOTE]
> `ctx` is optional. If you do not need the arena allocator, IO access, or the Lua state, you can leave it out. The `!` in the return type is not optional: allocations can fail in Zig, so you must either handle the error (return a default value) or forward it. Forwarding means Lua users using `pcall` can catch the error and decide what to do.

Now we need to connect this function to the Shape. The first `.{}` in `Shape.Table` is the method map. Add `__tostring` there:

```zig
pub const ZUA_SHAPE = zua.Shape.Table(Vec2, .{
    .__tostring = toString,
}, .{});
```

Rebuild and test:

```lua
local vm = require("vecmath")
local a = vm.vec2(3, 4)
print(a)
```

Instead of `table: 0x...` you will see `vec2(3, 4)`.
