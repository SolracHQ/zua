# Methods and ZUA_META

Both `.table` and `.object` strategy types can have methods attached to them so Lua code can call them with `:` syntax. The method list is declared inside `ZUA_META`.

> [!NOTE]
> The `:` syntax in Lua is shorthand for passing the receiver as the first argument. `p:distance()` is exactly equivalent to `p.distance(p)`. zua decodes the first argument as `self` automatically.

## Declaring methods

Pass the method list as the second argument to `Meta.Table` or `Meta.Object`:

```zig
const Point = struct {
    pub const ZUA_META = zua.Meta.Table(Point, .{
        .distance = distance,
    });

    x: f64,
    y: f64,

    pub fn distance(self: Point) f64 {
        return std.math.sqrt(self.x * self.x + self.y * self.y);
    }
};
```

```lua
local p = makePoint(3, 4)
print(p:distance())  -- 5
```

The keys in the method list become the Lua method names. The values are Zig function references, and the same `ZuaFn.new` wrapper that works for top-level functions works here too, covered below.

## Self types for .table methods

For `.table` methods, `self` can be either the struct type or a `zua.Table` handle:

- `self: T` decodes the current field values from the Lua table into a Zig struct. The method gets a read-only snapshot; mutations to `self` do not affect the Lua table.
- `self: zua.Table` gives the method a live handle to the table so it can read and write fields directly.

Use `T` when you only need to read, and `zua.Table` when you need to mutate:

```zig
const Counter = struct {
    pub const ZUA_META = zua.Meta.Table(Counter, .{
        .value     = getValue,
        .increment = increment,
    });

    count: i32,

    pub fn getValue(self: Counter) i32 {
        return self.count;
    }

    pub fn increment(ctx: *zua.Context, self: zua.Table, delta: i32) !void {
        const current = try self.get(ctx, "count", i32);
        self.set(ctx, "count", current + delta);
    }
};
```

```lua
local c = makeCounter()
c:increment(5)
print(c:value())  -- 5
print(c.count)    -- 5  (fields are directly readable on table strategy)
```

## Self types for .object methods

For `.object` methods, `self` is a pointer to the live Zig value inside the userdata:

- `self: *T` gives direct mutable access.
- `self: T` by value gives a read-only snapshot; mutations do not affect the Lua userdata.

> [!WARNING]
> You cannot return `*T` from a function when `T` is an `.object` type. The metatable would be lost. Return `T` by value instead and let zua allocate the userdata automatically.

## Context in methods

`*zua.Context` can appear as the first parameter before `self` in any method. zua skips it when matching parameters to Lua arguments, the same way it does for top-level functions:

```zig
pub fn toString(ctx: *zua.Context, self: Point) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena(), "({d}, {d})", .{ self.x, self.y })
        catch return ctx.fail("out of memory");
}
```

## Metamethods

Names starting with `__` in the method list are treated as metamethods and registered directly on the metatable. Everything else goes into `__index`:

```zig
const Vec2 = struct {
    pub const ZUA_META = zua.Meta.Table(Vec2, .{
        .length     = length,
        .__tostring = toString,
        .__add      = add,
    });

    x: f64,
    y: f64,

    pub fn length(self: Vec2) f64 {
        return std.math.sqrt(self.x * self.x + self.y * self.y);
    }

    pub fn toString(ctx: *zua.Context, self: Vec2) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena(), "({d}, {d})", .{ self.x, self.y })
            catch return ctx.fail("out of memory");
    }

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
};
```

```lua
local a = makeVec(1, 2)
local b = makeVec(3, 4)
local c = a + b
print(tostring(c))  -- (4, 6)
```

## Customizing method error messages

Wrap a method in `ZuaFn.new` to control the error message when argument types do not match. The wrapper is optional and can be used on individual methods without affecting others:

```zig
const Counter = struct {
    pub const ZUA_META = zua.Meta.Object(Counter, .{
        .increment = zua.ZuaFn.new(increment, .{
            .parse_err_fmt = "Counter:increment expects (integer): {s}",
        }),
        .reset = reset,
    });

    count: i32 = 0,

    pub fn increment(self: *Counter, amount: i32) void {
        self.count += amount;
    }

    pub fn reset(self: *Counter) void {
        self.count = 0;
    }
};
```
