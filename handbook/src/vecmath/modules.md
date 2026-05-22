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
    vec2: @TypeOf(vec2_fn) = vec2_fn,
    vec3: @TypeOf(vec3_fn) = vec3_fn,
};
```

> [!NOTE]
> `@TypeOf(vec2_fn)` looks horrible, I know. We will fix it in the next chapter.

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

Build and test:

```lua
local vm = require("vecmath")

local a = vm.vec2(3, 4)
local b = vm.vec3(1, 2, 3)

print(a:length(), b:length())
print(b:cross(vm.vec3(0, 1, 0)))
```

`require("vecmath")` returns the module table. `vm.vec2` and `vm.vec3` are both available.
