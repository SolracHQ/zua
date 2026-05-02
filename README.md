# zua

A Zig toolkit for Lua 5.4 interop. Write Zig types and functions, pass them to Lua, and skip the ceremony: no stack arithmetic, no manual type mapping, no hand-rolled table traversal, no fighting longjmp to keep defer alive.

The Lua C API is expressive but exhausting at some point. Type checks are runtime branches on magic constants. Nested tables require building and decoding each level by hand. Userdata lifetime is manual. Error propagation via longjmp bypasses Zig defer, so allocations on the way in leak silently. zua solves all of that once so you do not solve it again in every file.

```zig
const Point = struct { x: f64, y: f64 };

fn distance(a: Point, b: Point) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

try globals.set(&ctx, "distance", distance);
```

```lua
print(distance({x=0, y=0}, {x=3, y=4}))  -- 5.0
print(distance({x=0, y=0}, "oops"))       -- error: distance expects (Point, Point): got string
```

# Installation

```sh
zig fetch --save git+https://github.com/SolracHQ/zua
```

```zig
const zua = b.dependency("zua", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zua", zua.module("zua"));
```

No system packages needed. Lua and isocline are pulled as Zig packages automatically.

# What it offers

## Type mapping in both directions.

Structs, unions, enums, slices, optionals, and nested containers are handled automatically via comptime dispatch. No registration, no runtime reflection: the encode and decode paths are resolved at compile time from the type itself.

## Three object strategies.

`.table` for plain data, `.object` for GC-managed userdata with methods and `__gc`, `.ptr` for light userdata pointers.

## Encode and decode hooks.

Customize how any type crosses the boundary without abandoning the automatic path for everything else. Declare a hook once and the pipeline picks it up everywhere that type appears.

## Safe error propagation.

`ctx.fail` and `ctx.failWithFmt` propagate errors as typed Zig errors instead of longjmping over your defer statements.

## Memory management.

`ctx.arena()` for call-scoped allocations, `ctx.heap()` for persistent allocations, both available inside any lua function including `__gc` so owned resources can be freed safely when Lua collects an object.

## Closures.

`Meta.Capture` and `Native.closure` for stateful callbacks and partial application. The capture struct lives as userdata in the closure's upvalue and follows the same GC lifecycle as any object.

## List-style object support.

`zua.Meta.List` makes sequence-like userdata behave like Lua lists, with `__index`, `__len`, and iterator support built in.

## Handles and ownership.

Borrowed, stack-owned, and registry-owned handles with explicit transfer via `takeOwnership` and `release`. Hold a `zua.Function` in the registry and call it later with typed arguments and a typed return.

## Doc generation.

`zua.Docs` emits Lua stub files from the same metadata the encoder uses, so editor completion always reflects the current API without writing or maintaining stubs by hand.

## Built-in REPL.

`zua.Repl.run` drops a full interactive shell into any project, with persistent history, tab completion, and syntax highlighting.

## Shared library support.

`State.libState` attaches the zua machinery to an existing `lua_State`, so you can publish a native module loadable with `require` without owning the VM.

# Longer examples

Expose a stateful type as a Lua object with methods:

```zig
const Counter = struct {
    pub const ZUA_META = zua.Meta.Object(Counter, .{
        .increment = increment,
        .value = getValue,
        .__tostring = toString,
    });

    count: i32 = 0,

    fn increment(self: *Counter, amount: i32) void { self.count += amount; }
    fn getValue(self: *Counter) i32 { return self.count; }
    fn toString(ctx: *zua.Context, self: *Counter) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena(), "Counter({d})", .{self.count});
    }
};

try globals.set(&ctx, "Counter", makeCounter);
```

```lua
local c = Counter()
c:increment(5)
print(c)  -- Counter(5)
```

# Demo binary

The repo includes a small `zua` binary that demonstrates what the library can do. Think of it like `lua` itself: useful for quick experiments, but the real value of zua is using it as a dependency to build Zig code that interacts with Lua.

```sh
just run help
just run repl
just run eval return 2 + 3
just run docs
```

# Run the Examples

```sh
just list-examples              # list available examples
just run-example guided-tour    # run a specific one
just example                    # pick one interactively with fzf
just dylib                      # build and run the shared library example
```

# Documentation

The full handbook is at <https://solrachq.github.io/zua/>. It covers type mapping, object lifecycle, encode and decode hooks, handles and ownership, closures, the REPL, doc generation, and shared library support.

To build the handbook locally:

```sh
just docs
```

# Dependencies

- [SolracHQ/lua](https://github.com/SolracHQ/lua): a fork of Lua 5.4 with a `build.zig` added, pulled as a Zig package.
- [isocline](https://github.com/daanx/isocline): line-editing backend for the REPL.

# License

MIT, see [LICENSE](LICENSE).

> [!NOTE]
> All my machines run Fedora Linux, so I am unable to test on Windows or macOS. I occasionally test Windows with Vagrant but I know that is not the same. If you are able to test on either platform and run into issues, please open an issue, I would be really thankful for the help.
