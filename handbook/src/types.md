# Types

Tables are good for DTOs, plain data you want Lua to read and write. But sometimes you need a Zig value that has identity, methods, and a lifetime that Lua does not control. That is what translation strategies and the `ZUA_META` declaration are for.

## Translation strategies

Declare `ZUA_META` on a struct to tell zua how to represent it in Lua. There are three options.

### `.object` - userdata with methods

The struct is allocated as Lua userdata with a metatable. Methods receive `self: *T`, so they can mutate the value. This is the right choice when the value needs to stay in Zig-owned memory and Lua should interact with it through a defined interface.

```zig
const Entry = struct {
    pub const ZUA_META = zua.meta.Object(Entry, .{
        .get = get,
        .set = set,
        .__tostring = toString,
    });

    address: u64,
    value: f64,

    pub fn get(self: *Entry) Result(f64) {
        return Result(f64).ok(self.value);
    }

    pub fn set(self: *Entry, v: f64) Result(.{}) {
        self.value = v;
        return Result(.{}).ok(.{});
    }

    pub fn toString(z: *Zua, self: *Entry) Result([]const u8) {
        const arena = z.arena.?;
        const msg = std.fmt.allocPrint(arena, "Entry(0x{X}, {d})", .{
            self.address, self.value,
        }) catch return Result([]const u8).errStatic("out of memory");
        return Result([]const u8).ok(msg);
    }
};
```

```lua
local e = make_entry(0xdeadbeef)
e:set(8.3)
print(e:get())       -- 8.3
print(tostring(e))   -- Entry(0xDEADBEEF, 8.3)
```

### `.table` - Lua table with methods

Fields become table keys. Lua code can read and write them directly. Methods receive `self: T` for read-only access or `self: Table` when they need to mutate fields on the Lua side.

```zig
const Point = struct {
    pub const ZUA_META = zua.meta.Table(Point, .{
        .distance = distance,
    });

    x: f64,
    y: f64,

    pub fn distance(self: Point) Result(f64) {
        return Result(f64).ok(std.math.sqrt(self.x * self.x + self.y * self.y));
    }
};
```

```lua
local p = make_point()
p.x = 3
p.y = 4
print(p:distance())  -- 5
```

When no strategy is declared, `.table` is the default.

Tagged unions work naturally with `.table`. Lua passes a single-key table to select the active variant, zua decodes whichever field is present:

```zig
const Range = struct { min: f64, max: f64 };

const Condition = union(enum) {
    eq: f64,
    in_range: Range,

    pub const ZUA_META = zua.meta.Table(Condition, .{});
};
```

```lua
process:scan({ eq = 8.3 })
process:scan({ in_range = { min = 0, max = 255 } })
```

Only one field may be set; zero or more than one fails with a type error. Tagged unions can also use `.object` or `.zig_ptr` when you want the variant to stay opaque to Lua.

### `.zig_ptr` - opaque pointer

Light userdata. No methods, no metatable. Lua can hold the value and pass it back to Zig functions, but cannot inspect or modify it. This is the right choice for handles that should be completely opaque to Lua.

```zig
const Context = struct {
    pub const ZUA_META = zua.meta.Ptr(Context);

    multiplier: f64,
};

fn scale(ctx: *Context, value: f64) Result(f64) {
    return Result(f64).ok(value * ctx.multiplier);
}
```

```lua
local ctx = get_context()
print(scale(ctx, 10))
```

## Methods and metamethods

Methods are declared in the `ZUA_META` via `meta.Object()`, `meta.Table()` etc. as a comptime tuple of name-function pairs. Names starting with `__` are metamethods and go directly on the metatable. Everything else goes in `__index`.

```zig
const T = struct {
    pub const ZUA_META = zua.meta.Object(T, .{
        .normalize = normalize,
        .__tostring = toString,
        .__add = add,
    });

    // ...
};
```

The first parameter of a method determines how `self` is received:

- `.object`: `self: *T` for mutable access, or `*Zua` then `*T`
- `.table`: `self: T` for read-only, `self: Table` for mutable, or `*Zua` first in either case

Metamethods follow the same rules. `__tostring` and binary operators like `__add` and `__mul` work as you would expect from the Lua manual.

### Customizing method error handling

Methods can be wrapped in `ZuaFn` to customize error handling. Instead of a bare function, use `ZuaFn.from()` or `ZuaFn.pure()` with a `ZuaFnErrorConfig` to control how Zig errors are reported to Lua:

```zig
const Counter = struct {
    pub const ZUA_META = zua.meta.Object(Counter, .{
        .increment = zua.ZuaFn.pure(increment, .{
            .zig_err_fmt = "increment failed: {s}",
        }),
    });

    count: i32 = 0,

    pub fn increment(self: *Counter, amount: i32) Result(.{}) {
        self.count += amount;
        return Result(.{}).ok(.{});
    }
};
```

## Custom hooks

Sometimes you need control over how a type encodes to Lua or decodes from Lua. Use `.withEncode()` and `.withDecode()` builder methods on the `ZUA_META` declaration.

### Encode hooks

An encode hook transforms a value into a different type before it is pushed to Lua. The classic use is encoding an enum as a string instead of an integer:

```zig
const Status = enum(u8) {
    idle = 0,
    running = 1,
    stopped = 2,

    pub const ZUA_META = zua.meta.Table(Status, .{})
        .withEncode([]const u8, encodeAsString);

    fn encodeAsString(status: Status) []const u8 {
        return switch (status) {
            .idle => "idle",
            .running => "running",
            .stopped => "stopped",
        };
    }
};
```

The hook must return a different type than its input. This is enforced to prevent infinite recursion.

For enums specifically, `strEnum()` derives both hooks automatically from field names so you do not need to write the switch:

```zig
const Direction = enum { north, east, south, west };

// directly on the enum
pub const ZUA_META = zua.meta.Table(Direction, .{}).strEnum();
```

### Decode hooks

A decode hook lets a type accept multiple Lua value types and convert them. The hook receives a `Primitive` union that wraps the decoded Lua value as one of several types:

```zig
const Address = struct {
    pub const ZUA_META = zua.meta.Table(Address, .{})
        .withDecode(decodeHook);

    value: u64,

    fn decodeHook(z: *zua.Zua, primitive: zua.translation.Primitive) !zua.result.Result(Address) {
        return switch (primitive) {
            .integer => |n| zua.result.Result(Address).ok(.{ .value = @intCast(n) }),
            .userdata => |ptr| blk: {
                const addr_ptr: *Address = @ptrCast(@alignCast(ptr));
                break :blk zua.result.Result(Address).ok(.{ .value = addr_ptr.value });
            },
            else => zua.result.Result(Address).errOwned(z, "expected integer or userdata, got {s}", .{@tagName(primitive)}),
        };
    }
};
```

The `Primitive` union includes `.integer`, `.float`, `.boolean`, `.string`, `.table` (borrowed handle), `.function` (borrowed handle), `.light_userdata`, `.userdata`, and others. The hook should return a `Result(T)` to allow custom error messages that propagate through the decode chain.

Now any function that takes an `Address` parameter accepts both integers and userdata handles from Lua without any changes to the function itself.

### Asymmetry is fine

Encode and decode hooks are independent. You can have a type that encodes as a string but still decodes from an integer. The asymmetry is intentional, not a limitation.