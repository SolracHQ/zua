# Structured data

Scalars only get you so far. Most APIs pass tables back and forth, Lua's all-purpose container for structured data. This chapter covers decoding Lua tables into Zig structs, building tables in Zig to push back to Lua, and working with tagged unions.

## Structs as arguments

When a Lua caller passes a table, declare the matching Zig struct as a parameter and zua decodes the fields by name automatically:

```zig
fn printConfig(config: struct {
    name: []const u8,
    version: i32,
}) void {
    std.debug.print("{s} v{d}\n", .{ config.name, config.version });
}
```

```lua
printConfig({ name = "myapp", version = 1 })
```

Any named struct works just as well. The anonymous inline struct is convenient when the type is used in only one place. Optional fields decode as `null` when the key is missing or `nil` in the Lua table, and nested structs decode recursively from nested tables:

```zig
const Range = struct { min: f64, max: f64 };

const ScanOptions = struct {
    type_name: []const u8,
    eq:        ?f64,
    in_range:  ?Range,
};
```

Both of these work from Lua:

```lua
{ type_name = "f32", eq = 8.3 }
{ type_name = "u32", in_range = { min = 0, max = 255 } }
```

> [!NOTE]
> Struct decoding only reads string keys. Extra keys in the Lua table are silently ignored. Missing non-optional fields produce a type error.

## Returning structs to Lua

Return a struct directly and zua pushes a Lua table with matching string keys:

```zig
fn makePoint() struct { x: f64, y: f64 } {
    return .{ .x = 3.0, .y = 4.0 };
}
```

```lua
local p = makePoint()
print(p.x, p.y)  -- 3   4
```

## Tagged unions

Tagged unions work naturally with the `.table` strategy. Lua passes a single-key table to select the active variant:

```zig
const Range = struct { min: f64, max: f64 };

const Condition = union(enum) {
    eq:       f64,
    in_range: Range,

    pub const ZUA_META = zua.Meta.Table(Condition, .{}, .{});
};
```

```lua
process({ eq = 8.3 })
process({ in_range = { min = 0, max = 255 } })
```

zua decodes whichever field is present. If zero or more than one key is set, it returns a type error.

## Building tables from Zig

Use `Table.from` to convert a Zig struct or array literal to a Lua table in one call:

```zig
const guide = Table.from(state, .{
    .name    = "guided-tour",
    .version = 1,
    .tags    = [_][]const u8{ "zig", "lua" },
});
defer guide.release();
try state.addGlobals(&ctx, .{ .guide = guide });
```

Struct fields become string keys. Arrays and slices become array-style tables with integer keys starting at 1. Nesting is recursive. For incremental construction, use `Table.create` and `set`:

```zig
const entry = Table.create(state, 0, 3);
defer entry.release();
try entry.set(&ctx, "address", "0x7fff1234");
try entry.set(&ctx, "type",    "f32");
try entry.set(&ctx, "value",   8.3);
try state.addGlobals(&ctx, .{ .entry = entry });
```

> [!NOTE]
> `Table.create(state, narray, nrec)` is a hint to Lua about how many array-style and record-style entries the table will hold. Lua uses this to pre-allocate the right internal structures. Getting it wrong does not break anything, but getting it right avoids rehashing.

Tables returned from `Table.create` are **stack-owned handles** and must be `.release()`d before the enclosing scope returns. The `defer` pattern above is the standard idiom.

## Reading a table you already have

When you hold a `Table` handle, read individual fields with `get` and check existence with `has`:

```zig
const name    = try guide_table.get(&ctx, "name",    []const u8);
const version = try guide_table.get(&ctx, "version", i32);

if (guide_table.has("tags")) {
    // ...
}
```

For decoding many fields at once, `Decoder.decodeStruct` fills a struct by field name:

```zig
const guide = try zua.Mapper.Decoder.decodeStruct(&ctx, guide_table, struct {
    name:    []const u8,
    version: i32,
});
```

## Returning a table from a callback

Return `zua.Table` directly from a function. The trampoline takes ownership and passes it to Lua; you do not call `.release()` yourself in this case:

```zig
fn makeEntry(ctx: *zua.Context, address: []const u8) zua.Table {
    const t = Table.create(state, 0, 2);
    t.set(ctx, "address", address);
    t.set(ctx, "type",    "f32");
    return t;
}
```

## Typed table views

When a Lua value is already a table and you want a typed mutable view of it, use `zua.TableView(T)`. This decodes the table into a typed copy of `T` while keeping the raw `Table` handle so changes can be flushed back into the original Lua table.

```zig
pub fn translate(ctx: *zua.Context, self: zua.TableView(Vector2), dx: f64, dy: f64) void {
    self.ref.x += dx;
    self.ref.y += dy;
    self.sync(ctx);
}
```

`self.ref` is a pointer to the decoded typed copy. Mutate it freely, then call `self.sync(ctx)` to write changes back. If the view is returned from the function rather than mutated in place, `encode` handles the sync automatically.
