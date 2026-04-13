# zua

zua is a Zig library for embedding Lua. It is comptime-heavy by design: pushing values to Lua cannot fail because all types are known at compile time, while reading them can fail because Lua is a dynamic language and we depend on whatever the caller passes. The goal is to write Zig like Zig, write Lua like Lua, and have everything in between just work.

```zig
fn add(a: i32, b: i32) i32 {
    return a + b;
}

globals.set(&ctx, "add", add);
```

```lua
print(add(1, 2))    -- 3
print(add("oops"))  -- error: add expects (i32, i32): got string
```

The library grew beyond simple bindings because lifetime considerations, ownership rules, and things that cannot be represented cleanly on either side all need somewhere to live. The API tries to stay clean regardless. You should never need to touch `zua.lua` directly, even though it is there if you do.

All dependencies are vendored. No supply chain concerns: only `linenoise` for the embedded REPL and Lua 5.4 copied from its official repository. Both are MIT-compatible; their licenses are in `vendor/`.

The library is heavily inspired by [mlua](https://github.com/mlua-rs/mlua), the best Lua bindings I have ever seen. Unfortunately those are for Rust.

## What is new in 0.7.0

A lot of rework across the full library. The complete list is in the changelog, but the highlights are:

- The `Result` API is gone. I was so biased following mlua that I forgot Zig is not Rust, for good and for bad. The error path felt unnatural; not being able to just `try` was painful. Now functions return plain `!T` and errors propagate like normal Zig.
- A built-in REPL with syntax highlighting, tab completion, and persistent history, usable in roughly 5 lines of setup code.
- New handle types, typed wrappers, and closure support with captured mutable state.

## Handbook

The handbook walks through the full API from a simple `add` function to opaque objects, closures, and the REPL, without touching the Lua C API once.

The handbook intentionally repeats some content across chapters so readers can pick a single chapter and still understand the API without having to read everything else first.

```sh
cd handbook
mdbook serve
```

Then open http://localhost:3000. The handbook is also published at [solrachq.github.io/zua](https://solrachq.github.io/zua/) on the main branch.

## Platforms

I develop on Linux (Fedora). Windows and macOS might work but are not actively supported. If you hit issues on other platforms, open an issue.

## Installation

```sh
zig fetch --save git+https://github.com/SolracHQ/zua
```

```zig
const zua = b.dependency("zua", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zua", zua.module("zua"));
```

To pin a specific commit, add zua to `build.zig.zon` directly:

```zig
.dependencies = .{
    .zua = .{
        .url  = "https://github.com/solracHQ/zua/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

Lua 5.4 is included as vendored source under `vendor/lua`. No system Lua package is required, no submodule initialization either. Just clone and build:

```sh
git clone https://github.com/SolracHQ/zua.git
```

## License

MIT, see [LICENSE](LICENSE).