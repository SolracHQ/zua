# Setting up the project

The first step is to set up our project. This is a Zig library, so we need a Zig project.

Create a directory for the project:

```bash
mkdir -p ~/coding/vecmath
cd ~/coding/vecmath
```

You can use whatever folder you want here. You can also skip this step if you are adding zua to an existing project.

Then initialize the project:

```bash
zig init --name vecmath
```

This generates four files: `build.zig`, `build.zig.zon`, `src/main.zig`, and `src/root.zig`.

Now we need to add zua as a dependency. Run this from the project root:

```bash
zig fetch --save git+https://github.com/SolracHQ/zua
```

This adds zua to the `dependencies` section of `build.zig.zon`.

Next we need to modify `build.zig`. By default it produces an executable, but we need a dynamic library that Lua can load with `require`.

> [!NOTE]
> If this is your first time with `build.zig`, do not worry. It looks like a big file but most of it is just comments. Zig's build system is pretty simple once you get used to it.

Remove the executable section and replace it with a library:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zua_dep = b.dependency("zua", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "vecmath",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zua", .module = zua_dep.module("zua") },
            },
        }),
    });
    lib.root_module.link_libc = true;
    b.installArtifact(lib);
}
```

> [!NOTE]
> The `.name` field in `addLibrary` determines the output file name. On Linux this produces `libvecmath.so`. Lua expects `vecmath.so` (without the `lib` prefix). You can either rename the file after building, or add `;./lib?.so` to `package.cpath` in your test scripts.

Now write the entry point in `src/main.zig`:

```zig
const std = @import("std");
const zua = @import("zua");
const lua = zua.Bindings.lua;

export fn luaopen_vecmath(L: *lua.State) c_int {
    var threaded = std.Io.Threaded.init(std.heap.c_allocator, .{});
    const io = threaded.io();

    const state = zua.State.libState(L, std.heap.c_allocator, io, "vecmath") catch return 0;
    var ctx = zua.Context.init(state);
    defer ctx.deinit();
    zua.Mapper.Encoder.push(&ctx, "Hello Lua") catch return 0;
    return 1;
}
```

What is happening here? Let us go line by line.

First we initialize the Zig IO interface. This is important because the zua state holds it for any IO access (file access, console access, threading, async, random). It goes alongside the allocator, a familiar pattern in Zig.

Then we initialize the zua state with `State.libState`. This attaches zua to an existing Lua state instead of creating a new one. The `"vecmath"` suffix distinguishes this state from other zua-based libraries that might be loaded in the same Lua process. If the same suffix is used again, it returns the existing state instead of allocating a new one. This makes multiple `require` calls for the same library safe.

> [!NOTE]
> Use the name of your library as the state suffix. Since `require("name")` only loads a module once per Lua state, that name is effectively unique. But there is a deeper reason: the state holds the mapping from Zig type to metatable. If two libraries use the same type name, there will be a silent collision. One metatable gets attached to the wrong type, values get cast to the wrong type, and bad things happen :3.

Now we initialize the Context. The context is required everywhere in the zua API. Do not worry about it too much for now. This is the only one you will write by hand in this project. Inside callback functions, zua provides it automatically. For now, it just holds the error message in case `push` fails (even if pushing a string can never really fail).

Finally we return `1`, telling Lua that we pushed one return value.

Now build it:

```bash
zig build
```

This produces `zig-out/lib/libvecmath.so`. Lua expects `vecmath.so`, so rename it:

```bash
cp zig-out/lib/libvecmath.so vecmath.so
```

Or if you prefer, add this to your Lua test scripts:

```lua
package.cpath = package.cpath .. ";./lib?.so"
```

Now test it from Lua:

```lua
local vm = require("vecmath")
print(vm)
```

You should see `Hello Lua` printed to the console. We have a working dylib.
