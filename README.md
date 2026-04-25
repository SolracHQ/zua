# zua

A Zig library for embedding Lua. The goal is to make the boundary between the two languages mostly disappear: you pass Zig values to Lua, receive Lua values back into Zig, and none of it requires touching the Lua C API. Stack management, type conversion, memory allocation inside C callbacks, using `defer` without getting burned by `longjmp`, all handled automatically.

When something goes wrong, you know why. Type mismatches produce typed error messages. Arity errors tell you what was expected. Custom hooks give you full control over how any type maps across the boundary, in both directions.

## A taste

Run Lua from Zig and decode the result:

```zig
const state = try zua.State.init(gpa, io);
defer state.deinit();
var ctx = zua.Context.init(state);
defer ctx.deinit();
var executor = zua.Executor{};

const result = try executor.eval(&ctx, i32, .{ .code = .{ .string = "return 2 + 3" } });
// result == 5
```

Expose a Zig struct as a Lua table:

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

Expose a stateful Zig type as a Lua object with methods:

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

The [handbook](https://solrachq.github.io/zua/) covers all of it: structured data, object lifecycle, encode/decode hooks, closures, holding Lua callbacks from Zig, and the built-in REPL. zua also supports being built as a Lua shared library (`luaopen_<name>`) via `State.libState`, so you can publish a native module without owning the VM.

## Abstraction levels

zua is built in layers, all on top of the same encode/decode pipeline and raw handles. You can stop at any level:

- Raw handles: `Table`, `Function`, `Userdata`, `Primitive`. Safe wrappers with zero overhead and full manual control.
- Typed handles: `Fn(...)`, `Object(T)`, `TableView(T)`. Typed wrappers over handles with safe accessors.
- Mapped Zig types: structs, unions, enums decoded automatically. `.table` strategy is mostly type casts and field reads, close to zero allocation. `.object` is a pointer cast. `.ptr` is the same without methods.

The cost when crossing the boundary is the minimum possible. Comptime queries the struct shape directly, no reflection, no dynamic dispatch. You can mix levels freely.

## Installation

```sh
zig fetch --save git+https://github.com/SolracHQ/zua
```

```zig
const zua = b.dependency("zua", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zua", zua.module("zua"));
```

## Dependencies

- [SolracHQ/lua](https://github.com/SolracHQ/lua): a fork of Lua 5.4 with a `build.zig` added. Pulled as a Zig package. I try to keep it updated when new Lua versions come out.
- [isocline](https://github.com/daanx/isocline): line-editing backend used by the REPL, with multiline editing and syntax highlighting support.

No system packages needed.

## Notes

Developed on Linux (Fedora). Windows and macOS are untested.

Inspired by [mlua](https://github.com/mlua-rs/mlua).

## License

MIT, see [LICENSE](LICENSE).