# Shared libraries

zua can run inside a shared library that Lua loads with `require`. The host Lua state already exists when your code starts, so you cannot call `State.init`. `State.libState` handles this case: it attaches a `State` to an existing `lua_State` and returns a pointer you can use normally from that point on.

## How module loading works

When Lua executes `require("vecmath")`, it looks for a shared library called `vecmath.so` (or `.dll` on Windows) and calls the exported C function `luaopen_vecmath`. That function must push one value onto the Lua stack and return `1`. Everything else is up to you.

On the Zig side, you export that function, initialize a `State` from the received `lua_State` pointer, push your module table using the normal encoder, and return.

## Writing a luaopen function

```zig
const std = @import("std");
const zua = @import("zua");
const lua = zua.lua;

// Your API types and functions go here.

const Vecmath = struct {
    pub const ZUA_META = zua.Meta.Table(Vecmath, .{}, .{
        .name = "vecmath",
    });
    vec2: @TypeOf(vec2_fn) = vec2_fn,
    lerp: @TypeOf(lerp_fn) = lerp_fn,
};

export fn luaopen_vecmath(L: *lua.State) c_int {
    ...
    zua.Mapper.Encoder.pushValue(&ctx, Vecmath{}) catch return 0;
    return 1;
}
```

> [!NOTE]
> I really don't like how this `luaopen_<name>` signature looks. If Zig allows generating declarations at comptime, I will hide all that complexity away. The fact that an internal helper like `zua.Mapper.Encoder.pushValue` is needed means I failed a bit on zua's principle of keeping you away from the Lua stack, but it was the cleanest way I found to implement it. If you find another way, please open an issue.

`State.libState` takes the `lua_State` pointer, an allocator, an `io` handle, and a compile-time suffix string. The suffix distinguishes this library's `State` from any other zua-based library loaded in the same Lua process. Use your module name.

`State.libState` stores the `State` in the Lua registry. If the function is called again for the same suffix, it returns the existing `State` without allocating a new one. This means module reloading and multiple `require` calls for the same library are safe.

The returned `*State` is owned by the Lua registry and cleaned up when Lua closes the state.

> [!WARNING]
> Never call `state.deinit()`. You do not own the Lua VM here. Calling `deinit()` will shut down the Lua VM and break everything.

## Encoding the module

`Mapper.Encoder.pushValue` encodes any Zig value as a Lua value. A struct literal with named fields becomes a Lua table, which is what `require` expects to return. All the usual encoding rules apply: functions are wrapped as Lua callables, types with `ZUA_META` use their declared strategy, and nested struct literals become nested tables.

```zig
export fn luaopen_vecmath(L: *lua.State) c_int {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    const io = threaded.io();

    const state = zua.State.libState(L, std.heap.c_allocator, io, "vecmath") catch return 0;
    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    zua.Mapper.Encoder.pushValue(&ctx, Vecmath{ .vec2 = .{}, .lerp = .{} }) catch return 0;
    return 1;
}
```

`ctx.deinit()` resets the call arena but does not close the `State`. It is safe to call here.

## Building the shared library

Add a shared library step to your `build.zig`:

```zig
const lib = b.addLibrary(.{
    .name = "vecmath",
    .linkage = .dynamic,
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/vecmath.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zua", .module = zua_dep.module("zua") },
        },
    }),
});
lib.root_module.link_libc = true;
b.installArtifact(lib);
```

Zig names the output `libvecmath.so`. Lua's default searcher also looks for `vecmath.so`, so you need to either rename the file or add a `package.cpath` entry that matches `lib?.so`:

```lua
package.cpath = package.cpath .. ";./lib?.so"
local vecmath = require("vecmath")
```

Or set `CPATH` in the environment before starting Lua, or copy the file to a location already on `package.cpath`.

## Exposing a docs function

A common pattern is to include a `docs()` function in the module that returns the editor stub text on demand. Script authors call it once and write the output to a file their language server can index.

```zig
fn docs(ctx: *zua.Context) ![]const u8 {
    return zua.Docs.generateModule(ctx.arena(), Vecmath{}, "vecmath");
}

const vec2_fn = zua.Native.new(vec2, .{}, .{
    .name = "vec2",
    .description = "Construct a new Vec2 value.",
    .args = &.{
        .{ .name = "x", .description = "Horizontal component." },
        .{ .name = "y", .description = "Vertical component." },
    },
});

const lerp_fn = zua.Native.new(lerp, .{}, .{
    .name = "lerp",
    .description = "Linearly interpolate between two Vec2 values.",
    .args = &.{
        .{ .name = "a", .description = "Starting vector." },
        .{ .name = "b", .description = "Ending vector." },
        .{ .name = "t", .description = "Interpolation factor (0.0 to 1.0)." },
    },
});

const Vecmath = struct {
    pub const ZUA_META = zua.Meta.Table(Vecmath, .{}, .{
        .name = "vecmath",
    });
    vec2: @TypeOf(vec2_fn),
    lerp: @TypeOf(lerp_fn),
};
```

```lua
local vecmath = require("vecmath")
-- Write vecmath.lua to disk, then point your editor at it.
print(vecmath.docs())
```

See [Docs generation](./docs.md) for the full API description.

## Error handling in luaopen

`State.libState` and `pushValue` both return errors. The correct response in a `luaopen_*` function is to return `0`, which tells Lua the module failed to load. The caller will receive a Lua error.

If you want to surface a more descriptive message, push a string before returning:

```zig
export fn luaopen_vecmath(L: *lua.State) c_int {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    const io = threaded.io();

    const state = zua.State.libState(L, std.heap.c_allocator, io, "vecmath") catch {
        lua.pushString(L, "vecmath: failed to initialize state");
        return lua.error_(L);
    };
    var ctx = zua.Context.init(state);

    zua.Mapper.Encoder.pushValue(&ctx, Vecmath{}) catch {
        ctx.deinit();
        lua.pushString(L, "vecmath: failed to encode module");
        return lua.error_(L);
    };
    ctx.deinit();
    return 1;
}
```

`lua.error_` raises a Lua error via a long jump and never returns normally. Because the long jump bypasses Zig's deferred calls, `defer ctx.deinit()` would not run. Call `ctx.deinit()` manually on every exit path: once before each `lua.error_` call and once on the success path before returning.
