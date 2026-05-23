# Docs

At this point we have a pretty decent library. But if you play with it you probably noticed an inconvenience: the LSP is not giving you any autocompletion at all. That is pretty obvious if we think about it. Lua only sees a machine code file with zero information about what your library does. We need to help Lua with that, and zua has exactly the tool for that.

The Lua language server supports definition-only files, where you define the shape of your library with zero code. zua provides a module to autogenerate this documentation. But too much talk. As Linux Torvalds says, talk is cheap, show me the code:

```zig
fn docs_fn(ctx: *zua.Context) ![]const u8 {
    return zua.Docs.generateModule(ctx.arena(), Vecmath{}, "vecmath");
}
```

Add it to `lib/module.zig` and register it in the Vecmath struct:

```zig
pub const Vecmath = struct {
    vec2: zua.Shape.Fn(vec2_fn, .{}) = .{},
    vec3: zua.Shape.Fn(vec3_fn, .{}) = .{},
    docs: zua.Shape.Fn(docs_fn, .{}) = .{},
};
```

Now call it from Lua:

```lua
local vm = require("vecmath")
local stubs = vm.docs()
print(stubs)
```

The output looks like this:

```lua
---@meta vecmath

---@class Vec2
---@operator add(Vec2): Vec2
---@operator sub(Vec2): Vec2
---@operator mul(number): Vec2
---@field x number
---@field y number
local Vec2 = {}

---@class Vec3
---@operator add(Vec3): Vec3
---@operator sub(Vec3): Vec3
---@operator mul(number): Vec3
---@field x number
---@field y number
---@field z number
local Vec3 = {}

---@class Vecmath
local Vecmath = {}

---@return Vec2
function Vec2:normalize() end

---@return Vec3
function Vec3:normalize() end

---@return number
function Vec2:length() end

---@param arg1 number
---@param arg2 number
---@return Vec2
function Vecmath.vec2(arg1, arg2) end

---@param arg1 number
---@param arg2 number
---@param arg3 number
---@return Vec3
function Vecmath.vec3(arg1, arg2, arg3) end

---@return string
function Vecmath.docs() end

return Vecmath
```

Save those stubs to a file and open it in your editor. The autocompletion works. But look closely at the function signatures: `arg1`, `arg2`, `arg3`. Not exactly helpful. And the classes have no descriptions. That is all the information zua had to work with, because Zig doc comments do not survive to comptime. The empty `.{}` arguments we have been leaving on every Shape call are where that information goes.

> [!NOTE]
> `---@meta vecmath` means the file is definitions only and applies to `require("vecmath")`. Class declarations are Lua's way of defining a table shape with its fields, operators, and methods. `return Vecmath` at the end is a contract saying whatever `require` returns matches this class.

Now write a script to save the stubs to a file:

```lua
local vm = require("vecmath")
local stubs = vm.docs()
local file = io.open("vecmath.d.lua", "w")
file:write(stubs)
file:close()
print("stubs written to vecmath.d.lua (" .. #stubs .. " bytes)")
```

> [!WARNING]
> If your editor does not automatically recognize the `.d.lua` file, you must configure your `.luarc.json`. Unfortunately that is out of the scope of the book, but the information is widely spread on the internet.

## Shape options

Every `.{}` we left empty along the way was a small debt. Time to pay it back.

Lets start fixing the function argx issue first, since it is the more confusing piece. Everything else has a name, only args has default ones.

Take the `Shape.Fn` on vec2_fn in module.zig:

```zig
zua.Shape.Fn(vec2_fn, .{})
```

That empty `.{}` can take a description and a list of arguments:

```zig
zua.Shape.Fn(vec2_fn, .{
    .description = "Construct a new Vec2 value.",
    .args = &.{
        .{ .name = "x", .description = "Horizontal component." },
        .{ .name = "y", .description = "Vertical component." },
    },
})
```

Now the stub generator writes `---@param x number # Horizontal component.` instead of `---@param arg1 number`.

The `Table` options work the same way. The second `.{}` we have been leaving empty:

```zig
zua.Shape.Table(Vec2, .{...}, .{
    .name = "Vec2",
    .description = "A 2D vector with component-wise operations.",
    .field_descriptions = .{
        .x = "Horizontal component.",
        .y = "Vertical component.",
    },
})
```

The `.name` sets the class name in stubs. Remember the note in the methods chapter about `arg1: expected f64, got table` being unhelpful? With `.args` on the functions, that error turns into `x: expected f64, got string`.

One more thing worth knowing: if you rename `x` to `x_coord` in Vec2 and forget to update `field_descriptions`, it breaks at compile time. Docs cannot go stale without you knowing about it.

Now update Vecmath with all this. Add `ZUA_SHAPE` back with the module name, and wrap the functions with `Fn` options:

```zig
const Transform = [3][3]f64;

const Vecmath = struct {
    pub const ZUA_SHAPE = zua.Shape.Table(Vecmath, .{}, .{
        .name = "vecmath",
    });

    vec2: zua.Shape.Fn(vec2_fn, .{
        .description = "Construct a new Vec2 value.",
        .args = &.{
            .{ .name = "x", .description = "Horizontal component." },
            .{ .name = "y", .description = "Vertical component." },
        },
    }) = .{},
    vec3: zua.Shape.Fn(vec3_fn, .{
        .description = "Construct a new Vec3 value.",
        .args = &.{
            .{ .name = "x", .description = "X component." },
            .{ .name = "y", .description = "Y component." },
            .{ .name = "z", .description = "Z component." },
        },
    }) = .{},
    lerp: zua.Shape.Fn(lerp_fn, .{
        .description = "Linearly interpolate between two Vec2 values.",
        .args = &.{
            .{ .name = "a", .description = "Starting vector." },
            .{ .name = "b", .description = "Ending vector." },
            .{ .name = "t", .description = "Interpolation factor (0.0 to 1.0)." },
        },
    }) = .{},
    identity: zua.Shape.Fn(identity_fn, .{
        .description = "Create an identity 3x3 transform matrix.",
    }) = .{},
    rotate: zua.Shape.Fn(rotate_fn, .{
        .description = "Rotate a transform matrix around the Z axis.",
        .args = &.{
            .{ .name = "t", .description = "Transform matrix." },
            .{ .name = "angle", .description = "Rotation angle in radians." },
        },
    }) = .{},
    scale: zua.Shape.Fn(scale_fn, .{
        .description = "Uniformly scale a transform matrix.",
        .args = &.{
            .{ .name = "t", .description = "Transform matrix." },
            .{ .name = "factor", .description = "Scale factor." },
        },
    }) = .{},
    apply: zua.Shape.Fn(apply_fn, .{
        .description = "Apply a transform to a Vec2.",
        .args = &.{
            .{ .name = "t", .description = "Transform matrix." },
            .{ .name = "v", .description = "Vector to transform." },
        },
    }) = .{},
    docs: zua.Shape.Fn(docs_fn, .{
        .description = "Generate editor stubs for the vecmath module.",
    }) = .{},
};
```

Rebuild and run the docs script again and vec2 looks like this:

```lua
---@class Vec2
---@field x number # Horizontal component.
---@field y number # Vertical component.
-- A 2D vector with component-wise operations.
local Vec2 = {}

-- Construct a new Vec2 value.
---@param x number # Horizontal component.
---@param y number # Vertical component.
---@return Vec2
function vecmath.vec2(x, y) end
```

Now we have the module level documentation solved. But if you look deeper, we are not done yet. The vector methods still have `arg1` and so on.

## How to document methods

Documenting methods works the same way as module functions. You can do it inline, right there in the method map:

```zig
.__add = zua.Shape.Fn(add, .{ .description = "Component-wise addition." }),
.dot = zua.Shape.Fn(dot, .{ .description = "Dot product.", .args = &.{.{ .name = "b" }} }),
```

For metamethods only description is needed, Lua already knows their arguments. For regular methods you add `.args` to name the parameters.

The disadvantage of this approach is that the shape becomes dense and hard to read, especially in cases where you host several methods. At the same time it is the simplest, just modify slightly what we currently have.

Or you can pull the methods out into their own constant:

```zig
const methods = .{
    .__add = zua.Shape.Fn(add, .{ .description = "Component-wise addition." }),
    .dot = zua.Shape.Fn(dot, .{ .description = "Dot product.", .args = &.{.{ .name = "b" }} }),
    ...
};

pub const ZUA_SHAPE = zua.Shape.Table(Vec2, methods, .{ ... });
```

This separates the method documentation from the shape, keeping a cleaner structure, separating the data documentation from the behavior documentation. But it still has the problem that the docs are outside the function.

Or if you want each method to carry its own documentation, declare it as its own struct with a `ZUA_SHAPE`:

```zig
const add = struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{ .description = "Component-wise addition." });
    fn impl(a: Vec2, b: Vec2) Vec2 { ... }
};
```

This is the cleanest approach, the docs live along the functions. But it is the most verbose by far, it makes the whole type dense to read. The method map stays clean with just `.__add = add` without `Shape.Fn` noise. You can combine approaches if you want, but I really do not recommend it because it gets confusing fast what is documented and what is not.

> [!NOTE]
> The reason there are multiple forms is the difference between Zig and Lua regarding functions. For Lua a function is a value. For Zig a function is a declaration, and declarations can only exist inside a container. `Shape.Fn` adapts to both: inside a `Table` or `Object` you use already declared functions, and inside functions you cannot declare other functions so you use the struct form.

I prefer the extracted constant approach, keeps `ZUA_SHAPE` short and the methods section is its own block. But I understand those who prefer the struct approach because it keeps the documentation tied to the implementation.

Using my preference the Vec2 and Vec3 methods constants will look something like this.

> [!NOTE]
> It will vary a lot depending on what you prefer. The content of the docs will be the same but the way you write it will vary.

```zig
const methods = .{
    .__add = zua.Shape.Fn(add, .{ .description = "Component-wise addition." }),
    .__sub = zua.Shape.Fn(sub, .{ .description = "Component-wise subtraction." }),
    .__mul = zua.Shape.Fn(mul, .{ .description = "Scalar multiplication." }),
    .__eq = zua.Shape.Fn(eq, .{ .description = "Equality comparison." }),
    .length = zua.Shape.Fn(length, .{ .description = "Euclidean norm." }),
    .dot = zua.Shape.Fn(dot, .{ .description = "Dot product.", .args = &.{.{ .name = "b", .description = "Right vector." }} }),
    .normalize = zua.Shape.Fn(normalize, .{ .description = "Unit vector, returns zeros if length is zero." }),
    .__tostring = toString,
};

pub const ZUA_SHAPE = zua.Shape.Table(Vec2, methods, .{ ... });

// ... rest of the struct stays the same ...

const methods = .{
    .__add = zua.Shape.Fn(add, .{ .description = "Component-wise addition." }),
    .__sub = zua.Shape.Fn(sub, .{ .description = "Component-wise subtraction." }),
    .__mul = zua.Shape.Fn(mul, .{ .description = "Scalar multiplication." }),
    .__eq = zua.Shape.Fn(eq, .{ .description = "Equality comparison." }),
    .length = zua.Shape.Fn(length, .{ .description = "Euclidean norm." }),
    .dot = zua.Shape.Fn(dot, .{ .description = "Dot product.", .args = &.{.{ .name = "b", .description = "Right vector." }} }),
    .cross = zua.Shape.Fn(cross, .{ .description = "Cross product.", .args = &.{.{ .name = "b", .description = "Right vector." }} }),
    .normalize = zua.Shape.Fn(normalize, .{ .description = "Unit vector, returns zeros if length is zero." }),
    .__tostring = toString,
};

pub const ZUA_SHAPE = zua.Shape.Table(Vec3, methods, .{ ... });
```

Run the docs script again and the stubs now include descriptions for methods:

```lua
-- Dot product.
---@param b Vec2 # Right vector.
---@return number
function Vec2:dot(b) end

-- Euclidean norm.
---@return number
function Vec2:length() end

-- Unit vector, returns zeros if length is zero.
---@return Vec2
function Vec2:normalize() end
```

Now we have a complete generated docs. I know it is a bit verbose, but it looks way better and believe me your Lua users will thank you. It will also serve you since now you will be able to test without needing to read the Zig code, and even better it will be in sync with your code. If you rename a field it will tell you are trying to document something that does not exist. And if you do not need docs, just leave `.{}`, nobody will complain.
