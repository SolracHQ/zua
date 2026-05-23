# Modules

We have a working Vec2 with methods, operators, and nice printing. But I also promised Vec3. Vec3 is in essence Vec2 with an extra component and a cross product, so lets just create it in `lib/vec3.zig`:

```zig
const std = @import("std");
const zua = @import("zua");

pub const Vec3 = struct {
    x: f64,
    y: f64,
    z: f64,

    pub const ZUA_SHAPE = zua.Shape.Table(Vec3, .{
        .__add = add,
        .__sub = sub,
        .__mul = mul,
        .__eq = eq,
        .length = length,
        .dot = dot,
        .cross = cross,
        .normalize = normalize,
        .__tostring = toString,
    }, .{});

    fn add(a: Vec3, b: Vec3) Vec3 { return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z }; }
    fn sub(a: Vec3, b: Vec3) Vec3 { return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z }; }
    fn mul(self: Vec3, factor: f64) Vec3 { return .{ .x = self.x * factor, .y = self.y * factor, .z = self.z * factor }; }
    fn eq(a: Vec3, b: Vec3) bool { return a.x == b.x and a.y == b.y and a.z == b.z; }
    fn length(self: Vec3) f64 { return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z); }
    fn dot(a: Vec3, b: Vec3) f64 { return a.x * b.x + a.y * b.y + a.z * b.z; }
    fn cross(a: Vec3, b: Vec3) Vec3 { return .{ .x = a.y * b.z - a.z * b.y, .y = a.z * b.x - a.x * b.z, .z = a.x * b.y - a.y * b.x }; }
    fn normalize(self: Vec3) Vec3 {
        const len = @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
        if (len == 0) return .{ .x = 0, .y = 0, .z = 0 };
        return .{ .x = self.x / len, .y = self.y / len, .z = self.z / len };
    }
    fn toString(ctx: *zua.Context, self: Vec3) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena(), "vec3({d}, {d}, {d})", .{ self.x, self.y, self.z }) catch
            ctx.failTyped([]const u8, "oom");
    }
};
```

As you can see it is basically the same, just a couple extra functions. Nothing new on the Lua side.

Now lets add the constructor functions to `main.zig`:

```zig
fn vec3_fn(x: f64, y: f64, z: f64) Vec3 {
    return .{ .x = x, .y = y, .z = z };
}
```

Now lets push one of them and test. But wait, can we push both? What happens if we push vec2 and then vec3? Does the user write `local vec2, vec3 = require("vecmath")`? Or `local vecmath = require("vecmath")` and then what?

## The module problem

In Lua, `require("name")` expects a single return value. Lua supports multiple returns, but `require` specifically looks for the first value and ignores the rest. Pushing two functions means the second one is lost.

> [!NOTE]
> I am not fully sure if this still applies to Lua 5.4, the threads I found about it are pretty old (like [this one](https://stackoverflow.com/questions/9470498/can-luas-require-function-return-multiple-results)). But in most places and guides the recommendation is always to return only one value from `require`.

So how do you expose multiple things? The answer is the same pattern Lua itself uses for modules: return a table. A table with named fields works like a namespace. `require` sees one value (the table), and the user accesses everything through it.

Maybe some of you expect an intricate solution or some complex mechanism. The reality is simpler. Lua is a simple language, so we have a hammer called table and this is a nail.

Lets then move everything into a new file like `lib/module.zig`:

```zig
const std = @import("std");
const zua = @import("zua");

const Vec2 = @import("vec2.zig").Vec2;
const Vec3 = @import("vec3.zig").Vec3;

fn vec2_fn(x: f64, y: f64) Vec2 {
    return .{ .x = x, .y = y };
}

fn vec3_fn(x: f64, y: f64, z: f64) Vec3 {
    return .{ .x = x, .y = y, .z = z };
}

pub const Vecmath = struct {
    vec2: zua.Shape.Fn(vec2_fn, .{}) = .{},
    vec3: zua.Shape.Fn(vec3_fn, .{}) = .{},
};
```

> [!NOTE]
> Yes, another empty `.{}`. You might be wondering what that is for and what `Shape.Fn` even is. All that will be explained in the next chapter.

Vecmath is a plain struct with no `ZUA_SHAPE`. The default strategy for Zig structs is a Lua table, and zua pushes each field as a Lua callable automatically. You could add more functions here and they would just appear as new fields in the module table.

Now `main.zig` becomes cleaner:

```zig
const std = @import("std");
const zua = @import("zua");
const lua = zua.Bindings.lua;

const Vecmath = @import("lib/module.zig").Vecmath;

export fn luaopen_vecmath(L: *lua.State) c_int {
    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    const io = threaded.io();

    const state = zua.State.libState(L, std.heap.c_allocator, io, "vecmath") catch return 0;
    var ctx = zua.Context.init(state);
    defer ctx.deinit();
    zua.Mapper.Encoder.push(&ctx, Vecmath{}) catch return 0;
    return 1;
}
```

The entry point just imports the module and pushes it. Everything else lives in `lib/`.

## Using it from Lua

Lets see if it works with this example:

```lua
local vm = require("vecmath")

print(vm)

local a = vm.vec2(3, 4)
local b = vm.vec3(1, 2, 3)

print(a:length(), b:length())
print(b:cross(vm.vec3(0, 1, 0)))
```

As you can see it returns a table. The table has our two functions, and we can still use them to generate vectors with all their methods. And we still have the same single push, I promise no stack playing, and as promised that is the only push we will do in the whole project.

## More module functions

Before we move on there is some unfinished business. A vector math library without `lerp`, transforms, and matrix application is not much of a vector math library. None of this teaches anything new about zua, but you need it to have a complete example to follow along with.

The only thing worth pointing out is `Transform`:

```zig
const Transform = [3][3]f64;
```

A fixed-size array maps to a Lua table with integer keys, same as a struct maps to a table with field names. Nested arrays become nested tables. `[3][3]f64` arrives in Lua as `{{1,0,0},{0,1,0},{0,0,1}}` with no extra work. Keep that in mind whenever you need to pass matrix-like data.

The rest is just math. Add these to `lib/module.zig`:

```zig
fn lerp_fn(a: Vec2, b: Vec2, t: f64) Vec2 {
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
}

fn identity_fn() Transform {
    return .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
}

fn rotate_fn(t: Transform, angle: f64) Transform {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{
        .{ t[0][0] * c + t[0][1] * s, -t[0][0] * s + t[0][1] * c, t[0][2] },
        .{ t[1][0] * c + t[1][1] * s, -t[1][0] * s + t[1][1] * c, t[1][2] },
        .{ t[2][0] * c + t[2][1] * s, -t[2][0] * s + t[2][1] * c, t[2][2] },
    };
}

fn scale_fn(t: Transform, factor: f64) Transform {
    return .{
        .{ t[0][0] * factor, t[0][1] * factor, t[0][2] * factor },
        .{ t[1][0] * factor, t[1][1] * factor, t[1][2] * factor },
        .{ t[2][0] * factor, t[2][1] * factor, t[2][2] * factor },
    };
}

fn apply_fn(t: Transform, v: Vec2) Vec2 {
    return .{
        .x = t[0][0] * v.x + t[0][1] * v.y + t[0][2],
        .y = t[1][0] * v.x + t[1][1] * v.y + t[1][2],
    };
}
```

Register them in `Vecmath`:

```zig
pub const Vecmath = struct {
    vec2: zua.Shape.Fn(vec2_fn, .{}) = .{},
    vec3: zua.Shape.Fn(vec3_fn, .{}) = .{},
    lerp: zua.Shape.Fn(lerp_fn, .{}) = .{},
    identity: zua.Shape.Fn(identity_fn, .{}) = .{},
    rotate: zua.Shape.Fn(rotate_fn, .{}) = .{},
    scale: zua.Shape.Fn(scale_fn, .{}) = .{},
    apply: zua.Shape.Fn(apply_fn, .{}) = .{},
};
```

And use them from Lua:

```lua
local mid = vm.lerp(a, b, 0.5)
print(mid.x, mid.y)

local t = vm.rotate(vm.scale(vm.identity(), 2), math.pi / 4)
local rotated = vm.apply(t, a)
print(rotated.x, rotated.y)
```
