# Methods and metamethods

We have a nice printed vector now, but the library is called vecmath. We have the vec, but not too much math yet. Before we add the operators, I need to explain something that might be confusing if you come from Zig and not Lua: methods and metamethods.

## Methods in Lua

Lua does not have classes. It has tables and functions. A method is just a function stored in a table. When you write:

```lua
local a = vm.vec2(3, 4)
print(a.length(a))
```

That works, but it is verbose. Lua provides sugar for this, the `:` syntax. `a:length()` is exactly equivalent to `a.length(a)`. The compiler inserts the table itself as the first argument.

On the Zig side, zua handles this automatically. When you declare a method in `ZUA_SHAPE`, the first parameter after `ctx` (if present) is the receiver. If your function takes `self: Vec2`, zua decodes it from the Lua call. You never see the colon syntax from Zig. You just write a function that takes the receiver as a parameter.

> [!NOTE]
> Technically you do not need to have the same type as the first argument of a method. You can put any function there and call it with `.` syntax instead of `:` and it will work. However, the docs generator will get confused. For standalone functions the `Shape.Fn` mechanism is preferred. It will be discussed later.

## Metamethods

Metamethods are methods with a special name that Lua calls automatically when you use an operator. They start with `__`. `__tostring` is one: Lua calls it when you pass the value to `print()` or `tostring()`. `__add` is another: Lua calls it when you use `+`.

The difference is simple:

- **Methods** are called explicitly with `:` syntax: `a:length()`.
- **Metamethods** are called implicitly by Lua when you use an operator: `a + b`.

Both are declared the same way in `ZUA_SHAPE`. The `__` prefix tells zua to register them in the metatable instead of the regular method list.

> [!NOTE]
> For performance we do not create a new metatable for each value. Instead they are cached in the zua state and attached when the type is returned by the encoder.

## Adding the operators

Now that we know the difference, lets add `__add`, `__sub`, `__mul`, and `__eq`. The pattern is the same as `__tostring`, write a Zig function and add it to the method map.

```zig
fn add(self: Vec2, other: Vec2) Vec2 {
    return .{ .x = self.x + other.x, .y = self.y + other.y };
}

fn sub(self: Vec2, other: Vec2) Vec2 {
    return .{ .x = self.x - other.x, .y = self.y - other.y };
}

fn mul(self: Vec2, factor: f64) Vec2 {
    return .{ .x = self.x * factor, .y = self.y * factor };
}

fn eq(a: Vec2, b: Vec2) bool {
    return a.x == b.x and a.y == b.y;
}
```

Notice `__mul` takes a Vec2 and an `f64`, not two Vec2s. Lua passes the right operand as the second argument regardless of its type. zua decodes it into whatever type the parameter declares, so scalar multiplication works naturally.

> [!NOTE]
> If you pass the wrong argument type, zua gives you an error message like `arg1: expected f64, got table`. The "arg1" part is not very helpful. We will learn how to customize error messages later and replace those generic names with the actual parameter name.

`__eq` returns `bool`, not Vec2. Each metamethod has its own return contract: `__add` returns the same type, `__eq` returns a boolean, `__tostring` returns a string. zua does not enforce this. You just write the Zig function with the return type that makes sense, and zua encodes it.

Register them in the method map alongside `__tostring`:

```zig
pub const ZUA_SHAPE = zua.Shape.Table(Vec2, .{
    .__tostring = toString,
    .__add = add,
    .__sub = sub,
    .__mul = mul,
    .__eq = eq,
    .length = length,
    .dot = dot,
    .normalize = normalize,
}, .{});
```

Now build and test:

```lua
local vm = require("vecmath")

local a = vm.vec2(3, 4)
local b = vm.vec2(1, 2)

local c = a + b
print(c)

local d = a - b
print(d)

local e = a * 2
print(e)

print(a == vm.vec2(3, 4))
print(a == b)
```

You will see `vec2(4, 6)`, `vec2(2, 2)`, `vec2(6, 8)`, `true`, and `false`.

Methods and metamethods follow the same rule: write a plain Zig function, add it to the `ZUA_SHAPE` method map, and it works. The only difference is who calls them.
