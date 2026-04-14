# zua

A Zig library for embedding Lua without the usual boilerplate. Stack management, type conversion, memory allocation inside C callbacks, and `defer` vs `longjmp` hazards are all handled automatically.

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

Argument decoding, return value encoding, and error dispatch happen automatically.
Type mapping and metatable generation happen at comptime, so the binding layer has no runtime overhead.

## Installation

```sh
zig fetch --save git+https://github.com/SolracHQ/zua
```

```zig
const zua = b.dependency("zua", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zua", zua.module("zua"));
```

Lua 5.4 is vendored under `vendor/lua`. No system Lua package is needed.

## What it covers

- Structs passed as Lua tables, with optional and nested fields
- Opaque objects with methods and `__gc` cleanup
- Custom encode/decode hooks for any type
- Closures with captured mutable state
- Callbacks: holding and calling Lua functions from Zig
- Variadic functions via `zua.VarArgs`
- A built-in REPL with syntax highlighting, tab completion, and persistent history

The [handbook](https://solrachq.github.io/zua/) walks through all of it from a simple `add` to full object lifecycle, without touching the Lua C API once.

## Notes

Developed on Linux (Fedora). Windows and macOS are untested. 
Vendored dependencies are `linenoise` and Lua 5.4, both MIT-compatible. 
Inspired by [mlua](https://github.com/mlua-rs/mlua).

## License

MIT, see [LICENSE](LICENSE).