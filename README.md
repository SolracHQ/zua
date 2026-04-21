# zua

A Zig library for embedding Lua where the boundary between the two languages mostly disappears. You pass Zig values to Lua, receive Lua values back into Zig, register functions, hold callbacks, build objects with metatables, and none of it requires touching the Lua C API. Stack management, type conversion, memory allocation inside C callbacks, using `defer` without getting burned by `longjmp`, all handled automatically.

When something goes wrong, you know why. Type mismatches produce typed error messages. Arity errors tell you what was expected. Custom hooks let you control exactly how any type maps across the boundary, in both directions.

```zig
const Point = struct { x: f64, y: f64 };

fn distance(a: Point, b: Point) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

globals.set(&ctx, "distance", distance);
```

```lua
print(distance({x=0, y=0}, {x=3, y=4}))  -- 5.0
print(distance({x=0, y=0}, "oops"))       -- error: distance expects (Point, Point): got string
```

The struct decoding, return value encoding, and error dispatch all happen at compile time. There is a small cost when crossing the boundary (reading fields, casting types), but it is the minimum possible. Comptime queries the struct shape directly, no reflection, no hash maps, no dynamic dispatch. If you wrote the glue by hand you would not do it faster.

If you need even less, you can drop down to the exact abstraction level you want:

- Raw handles: `Table`, `Function`, `Userdata`, `Primitive`. Direct Lua API access, zero overhead, full manual control.
- Typed handles: `Fn(...)`, `Object(T)`, `TableView(T)`. Typed wrappers over handles with safe accessors.
- Mapped Zig types: structs, unions, enums decoded automatically. `.table` strategy is mostly type casts and field reads, close to zero allocation. `.object` is a single pointer cast. `.ptr` is the same without methods.

You pick the level. You can mix freely.

## Installation

```sh
zig fetch --save git+https://github.com/SolracHQ/zua
```

```zig
const zua = b.dependency("zua", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zua", zua.module("zua"));
```

## What it covers

- Structs, unions, and enums crossing the boundary as Lua tables or userdata
- Opaque objects with methods, metamethods, and `__gc` cleanup
- Custom encode/decode hooks for full control over any type
- Closures with captured mutable state
- Holding and calling Lua functions from Zig
- Variadic functions via `zua.VarArgs`
- A built-in REPL with syntax highlighting, tab completion, and persistent history

The [handbook](https://solrachq.github.io/zua/) goes from a simple function to full object lifecycle, without touching the Lua C API once.

## Notes

Developed on Linux (Fedora). Windows and macOS are untested.

Lua 5.4 comes from [SolracHQ/lua](https://github.com/SolracHQ/lua), a fork of upstream Lua with a `build.zig` added so it can be fetched as a normal Zig dependency. I try to keep it updated when new Lua versions come out. `linenoise` is vendored directly. No system packages needed.

Inspired by [mlua](https://github.com/mlua-rs/mlua).

## License

MIT, see [LICENSE](LICENSE).