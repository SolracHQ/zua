# Docs

At this point we have a pretty decent library. But if you play with it you probably noticed an inconvenience: the LSP is not giving you any autocompletion at all. That is pretty obvious if we think about it. Lua only sees a machine code file with zero information about what your library does. We need to help Lua with that, and zua has exactly the tool for that.

The Lua language server supports definition-only files, where you define the shape of your library with zero code. zua provides a module to autogenerate this documentation.

But too much talk. As Linux Torvalds says, talk is cheap, show me the code:

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

Lets analyze what we are getting here. First `---@meta vecmath`. `@meta` means this file does not contain any executable code, only definitions. Any executable code in this file would be a warning. The name after `meta` means this file will apply over any `require` to this name.

Then we see that we declare two classes for Vec2 and Vec3. Lua does not really have types. Instead Lua annotates a table with a class definition, a name, which attributes it has, which operators, and which functions. If any other annotation refers to that class, Lua understands it will return something with the same contract the class defines.

The `Vec2:name()` syntax is sugar for `function Vec2.name(self: Vec2)`.

The `return Vecmath` at the end is saying that whatever `require` returns will match the contract of this value.

Now write a script to save the stubs to a file:

```lua
local vm = require("vecmath")
local stubs = vm.docs()
local file = io.open("vecmath.d.lua", "w")
file:write(stubs)
file:close()
print("stubs written to vecmath.d.lua (" .. #stubs .. " bytes)")
```

Your editor will start showing autocompletion, guessing the result types of operations, and a better experience in general. But you will also notice something awkward: the types have no descriptions, neither the functions. And `arg1`, `arg2` is confusing. But yeah, that is all the information zua has. Even if you add doc comments to types and functions, they are not carried by Zig's doc comments at comptime.

So there is no other option? There is. That is where the `.{}` we left on Shapes will start being useful.

> [!WARNING]
> If your editor does not automatically recognize the `.d.lua` file, you must configure your `.luarc.json`. Unfortunately that is out of the scope of the book, but the information is widely spread on the internet.

## Shape options

Along the road to reach this point we left several empty `.{}` on Shape variants, the second `.{}` in `Table` and the only one on `Fn`. I promised to explain it later and I am here to achieve my promises. Anyways it is nothing fancy, it is just the configuration struct, a very common pattern in Zig libraries where the function accepts a struct with defined defaults. You pass whatever configuration you want to override. In the case of Shape configuration it is mostly for documentation.

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

The options struct is generated based on the struct fields, so it checks at comptime that the field names match. Rename `x` to `x_coord` in Vec2 and `field_descriptions` breaks at compile time. Docs cannot go stale without you knowing.

Now update Vecmath with all this. Add `ZUA_SHAPE` back with the module name, and wrap the functions with `Fn` options:

```zig
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

Now we have a complete generated docs. I know it is a bit verbose, but it looks way better and believe me your Lua users will thank you. It will also serve you since now you will be able to test without needing to read the Zig code, and even better it will be in sync with your code. If you rename a field it will tell you are trying to document something that does not exist. And if you do not need docs, just leave `.{}`, nobody will complain.


