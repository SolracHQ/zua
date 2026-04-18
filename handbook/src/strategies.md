# Strategies

Every Zig type that crosses the Lua boundary has a **strategy** that controls how it is represented in Lua. The strategy is declared on the type itself via `pub const ZUA_META`. If no declaration is present, zua defaults to `.table`.

There are three strategies: `.table`, `.object`, and `.ptr`. Choosing the right one is about deciding what Lua should be able to see and do with a value.

## .table

The `.table` strategy represents a Zig struct as a Lua table. Fields become string keys, Lua code can read and write them directly, and the value is fully transparent.

```zig
const Point = struct {
    x: f64,
    y: f64,
};
```

No `ZUA_META` declaration means `.table` is used automatically. A function returning `Point` pushes a table with keys `x` and `y`. A function accepting `Point` decodes those keys from whatever table Lua passes.

Use `.table` for data transfer objects: values that carry information back and forth but have no identity and no private internals.

> [!NOTE]
> Table-strategy structs cannot contain raw `.object` values directly by value, and fields with `.ptr` strategy have no direct table representation. For nested object references, use `zua.Object(T)` handles instead of embedding `T` directly. This is covered in the [Object handles](./object-handles.md) chapter.

## .object

The `.object` strategy stores the value as Lua userdata. Lua holds a pointer to it and can call methods on it, but cannot read or write individual fields. The value is opaque.

```zig
const Entry = struct {
    pub const ZUA_META = zua.Meta.Object(Entry, .{
        .get = get,
        .set = set,
    });

    address: u64,
    value:   f64,

    pub fn get(self: *Entry) f64 { return self.value; }
    pub fn set(self: *Entry, v: f64) void { self.value = v; }
};
```

```lua
local e = makeEntry(0xDEADBEEF)
e:set(8.3)
print(e:get())    -- 8.3
print(e.address)  -- nil  (fields are not accessible)
```

Use `.object` when:
- the value has identity, a file handle, a connection, a scan context, something that should not be copied or decoded,
- the value contains types that cannot be represented in a Lua table, such as `u64` addresses whose high bits would be corrupted by Lua's `i64` integers,
- or you want to enforce that Lua code goes through methods and cannot touch internals.

The value is allocated as Lua userdata and its lifetime is managed by the Lua garbage collector. Methods are the only interface.

> [!WARNING]
> `ZUA_META` must be declared as `pub const ZUA_META`. If it is not public, zua will not see the metadata and the strategy, methods, and hooks on the type will not be applied.

## List-style objects

For sequence-like userdata values, use `zua.Meta.List(T, getElements, methods)` as a convenience builder.

This helper creates `.object` metadata for a container type and automatically generates the common Lua collection methods:

- `get(self, index)` returns the element at 1-based index or `nil`.
- `__index` makes `list[1]` syntax work.
- `__len` makes `#list` return the element count.
- `iter` supports `for x in list do` iteration.

`getElements` must be a comptime function returning a slice of the list's elements:

```zig
fn getElements(self: *ProcList) []zua.Object(Process) {
    return self.processes.items;
}
```

You can still add custom metadata like `__gc` and `__tostring`, but `Meta.List` reserves the generated method names and rejects collisions with user methods.

## .ptr

The `.ptr` strategy is the minimal opaque strategy: just a light userdata pointer. No metatable, no methods. Lua can hold the value and pass it back, but cannot do anything else with it.

```zig
const ScanContext = struct {
    pub const ZUA_META = zua.Meta.Ptr(ScanContext);
    multiplier: f64,
};
```

```lua
local ctx = getScanContext()
print(scale(ctx, 10))  -- Zig receives the *ScanContext back
```

Use `.ptr` for handles that need to be completely opaque and require no Lua-callable interface. Note that `.ptr` values must be pushed as `*T` pointers; you cannot return `T` by value for `.ptr` types.

> [!WARNING]
> Light userdata is a raw pointer. The pointed-to value must outlive the Lua state. zua does not track or manage that lifetime. If there is any chance the Lua state can outlive the pointed-to value, use `.object` instead, which ties the allocation to Lua's GC.

## Choosing a strategy

The decision usually comes down to one question: does Lua need to see the fields?

- Yes, it is data that Lua reads and writes: use `.table`.
- No, it is an opaque handle with a method interface: use `.object`.
- No, it is a raw pointer with no interface at all: use `.ptr`.

Most types end up as `.table` or `.object`. `.ptr` is for the rare case where you need maximum opacity with zero overhead.
