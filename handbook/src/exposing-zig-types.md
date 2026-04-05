# Exposing Zig Types

Declare `pub const ZUA_TRANSLATION_STRATEGY` and `pub const ZUA_METHODS` on a struct to expose it to Lua.

## `.object` — Userdata

Holds your struct instance as Lua userdata with a metatable. Methods receive `self: *T`.

```zig
const Entry = struct {
    pub const ZUA_TRANSLATION_STRATEGY: zua.translation.Strategy = .object;
    pub const ZUA_METHODS = .{
        .get = get,
        .set = set,
        .__tostring = toString,
    };

    value: f64,

    pub fn get(self: *Entry) zua.Result(f64) {
        return zua.Result(f64).ok(self.value);
    }

    pub fn set(self: *Entry, v: f64) zua.Result(.{}) {
        self.value = v;
        return zua.Result(.{}).ok(.{});
    }

    pub fn toString(z: *Zua, self: *Entry) zua.Result([]const u8) {
        const msg = std.fmt.allocPrint(z.allocator, "Entry({d})", .{self.value})
            catch return zua.Result([]const u8).errStatic("oom");
        return zua.Result([]const u8).owned(z, msg);
    }
};
```

```lua
local e = make_entry()
e:set(3.14)
print(e:get())      -- 3.14
print(tostring(e))  -- Entry(3.14)
```

## `.table` — Lua Table (default)

Struct fields become table fields. Methods receive `self: T` (immutable) or `self: Table` (mutable).

```zig
const Point = struct {
    pub const ZUA_TRANSLATION_STRATEGY: zua.translation.Strategy = .table;
    pub const ZUA_METHODS = .{
        .distance = distance,
    };

    x: f64,
    y: f64,

    pub fn distance(self: Point) zua.Result(f64) {
        const d = std.math.sqrt(self.x * self.x + self.y * self.y);
        return zua.Result(f64).ok(d);
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

## `.zig_ptr` — Light Userdata

Opaque pointer. Cannot have methods. Pass to Zig functions.

```zig
const Context = struct {
    pub const ZUA_TRANSLATION_STRATEGY: zua.translation.Strategy = .zig_ptr;
    multiplier: f64,
};

fn scale(ctx: *Context, value: f64) zua.Result(f64) {
    return zua.Result(f64).ok(value * ctx.multiplier);
}
```

```lua
local ctx = get_context()
print(scale(ctx, 10))
```

## Methods and Metamethods

Methods are declared in `ZUA_METHODS`. Names starting with `__` are metamethods (placed on the metatable directly); others go in `__index`.

```zig
pub const ZUA_METHODS = .{
    .normalize = normalize,     // regular method
    .__tostring = toString,     // metamethod
    .__add = add,               // operator overload
};

pub fn normalize(self: *Vector) zua.Result(.{}) {
    const len = std.math.sqrt(self.x * self.x + self.y * self.y);
    if (len > 0) {
        self.x /= len;
        self.y /= len;
    }
    return zua.Result(.{}).ok(.{});
}

pub fn toString(z: *Zua, self: *Vector) zua.Result([]const u8) {
    const msg = std.fmt.allocPrint(z.allocator, "Vector({d}, {d})", .{self.x, self.y})
        catch return zua.Result([]const u8).errStatic("oom");
    return zua.Result([]const u8).owned(z, msg);
}

pub fn add(z: *Zua, a: *Vector, b: *Vector) zua.Result(Vector) {
    return zua.Result(Vector).ok(.{ .x = a.x + b.x, .y = a.y + b.y });
}
```

```lua
local v1 = make_vector(3, 4)
local v2 = make_vector(1, 0)
print(v1 + v2)      -- Vector(4, 4)
v1:normalize()
print(v1)           -- Vector(0.6, 0.8)
```

Method first parameter detection:
- `.object`: `self: *T`
- `.table`: `self: T` or `self: Table`
- Optionally: `*Zua` as first param to access allocator

Metamethods: `__tostring`, `__add`, `__sub`, `__mul`, `__div`, `__eq`, `__lt`, `__le`, `__index`, `__newindex`, etc.
