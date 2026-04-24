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

const module = .{ .vec2 = vec2_fn, .lerp = lerp_fn };

export fn luaopen_vecmath(L: *lua.State) c_int {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    const io = threaded.io();

    const state = zua.State.libState(L, std.heap.c_allocator, io, "vecmath") catch return 0;
    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    zua.Mapper.Encoder.pushValue(&ctx, module) catch return 0;
    return 1;
}
```

`State.libState` takes the `lua_State` pointer, an allocator, an `io` handle, and a compile-time suffix string. The suffix distinguishes this library's `State` from any other zua-based library loaded in the same Lua process. Use your module name.

`State.libState` stores the `State` in the Lua registry. If the function is called again for the same suffix, it returns the existing `State` without allocating a new one. This means module reloading and multiple `require` calls for the same library are safe.

The returned `*State` is owned by the Lua registry and cleaned up when Lua closes the state. Do not call `state.deinit()`.

## Encoding the module

`Mapper.Encoder.pushValue` encodes any Zig value as a Lua value. A struct literal with named fields becomes a Lua table, which is what `require` expects to return. All the usual encoding rules apply: functions are wrapped as Lua callables, types with `ZUA_META` use their declared strategy, and nested struct literals become nested tables.

```zig
export fn luaopen_vecmath(L: *lua.State) c_int {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    const io = threaded.io();

    const state = zua.State.libState(L, std.heap.c_allocator, io, "vecmath") catch return 0;
    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    zua.Mapper.Encoder.pushValue(&ctx, module) catch return 0;
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
    return zua.Docs.generateModule(ctx.arena(), module, "vecmath");
}

const docs_fn = zua.Native.new(docs, .{})
    .withName("docs")
    .withDescription("Generate editor stubs for the vecmath module.");

const module = .{ .vec2 = vec2_fn, .lerp = lerp_fn, .docs = docs_fn };
```

```lua
local vecmath = require("vecmath")
-- Write vecmath.lua to disk, then point your editor at it.
print(vecmath.docs())
```

The stub is generated at runtime from the same metadata the encoder uses, so it always reflects the current API. See [Stub generation](./stubs.md) for the full description of what gets emitted.

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

    zua.Mapper.Encoder.pushValue(&ctx, module) catch {
        ctx.deinit();
        lua.pushString(L, "vecmath: failed to encode module");
        return lua.error_(L);
    };
    ctx.deinit();
    return 1;
}
```

`lua.error_` raises a Lua error via a long jump and never returns normally. Because the long jump bypasses Zig's deferred calls, `defer ctx.deinit()` would not run. Call `ctx.deinit()` manually on every exit path: once before each `lua.error_` call and once on the success path before returning.
