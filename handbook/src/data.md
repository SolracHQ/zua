# Data

Most real APIs pass more than a few scalars. This chapter covers how to move structured data across the boundary in both directions.

## Structs as function arguments

When a Lua caller passes a config table, declare the corresponding Zig struct as a parameter and zua decodes the fields automatically:

```zig
fn printConfig(_: *Zua, config: struct {
    name: []const u8,
    version: i32,
}) Result(.{}) {
    std.debug.print("{s} v{d}\n", .{ config.name, config.version });
    return Result(.{}).ok(.{});
}
```

```lua
printConfig({ name = "myapp", version = 1 })
```

Any named struct works too, the inline form is just convenient when the type is only used once.

Optional fields decode as `null` when the Lua table does not have that key or has `nil` for it. Nested structs decode recursively from nested Lua tables:

```zig
const Range = struct { min: f64, max: f64 };

const ScanOptions = struct {
    type_name: []const u8,
    eq: ?f64,
    in_range: ?Range,
};
```

This decodes both:

```lua
{ type_name = "f32", eq = 8.3 }
{ type_name = "u32", in_range = { min = 0, max = 255 } }
```

## Sum types

Lua tables that represent a sum type, where only one of several optional fields is present, do not map directly to Zig tagged unions. Decode into a flat struct first, then convert:

```zig
const Condition = union(enum) { eq: f64, in_range: Range };

fn decodeCondition(eq: ?f64, in_range: ?Range) !Condition {
    if (eq != null and in_range != null) return error.InvalidType;
    if (eq) |v| return .{ .eq = v };
    if (in_range) |r| return .{ .in_range = r };
    return error.InvalidType;
}
```

The two-step approach is intentional. Struct decode handles the mechanical field extraction. Your conversion function encodes the validation rules and error messages that belong to your domain. You can see this pattern in practice in the memscript API example, where scan options arrive as a flat table and get converted to a `Condition` union before any logic runs.

## Building tables to return

Use `tableFrom` when you already have data you want to push to Lua:

```zig
const guide = z.tableFrom(.{
    .name = "guided-tour",
    .version = 1,
    .tags = [_][]const u8{ "zig", "lua" },
});
defer guide.pop();
globals.set("guide", guide);
```

Struct fields become string keys. Arrays and slices become array-style Lua tables. Nesting is recursive.

When you need to build a table incrementally, use `createTable` and `set`:

```zig
const entry = z.createTable(0, 3);
defer entry.pop();
entry.set("address", "0x7fff1234");
entry.set("type", "f32");
entry.set("value", 8.3);
globals.set("entry", entry);
```

## Returning a table from a callback

Return `Result(Table)` and push the table as the return value:

```zig
fn makeEntry(z: *Zua, address: []const u8) Result(Table) {
    const t = z.createTable(0, 2);
    t.set("address", address);
    t.set("type", "f32");
    return Result(Table).ok(t);
}
```

The trampoline pushes the table value and pops the handle after your function returns.

## Adding methods to tables

Methods are Zig functions registered on a table. Lua calls them with `:` syntax, which passes the receiver table as the first argument:

```zig
fn increment(_: *Zua, self: Table, delta: i32) Result(i32) {
    const current = self.get("count", i32)
        catch return Result(i32).errStatic("count missing");
    const next = current + delta;
    self.set("count", next);
    return Result(i32).ok(next);
}

const counter = z.tableFrom(.{ .count = 0 });
defer counter.pop();
counter.setFn("increment", ZuaFn.from(increment, .{
    .parse_error = "counter:increment expects (i32)",
}));
globals.set("counter", counter);
```

```lua
counter:increment(5)
```

## Decoding a table you already have

When you have a `Table` handle rather than a direct function argument, use `translation.decodeStruct`:

```zig
const guide_table = try globals.get("guide", zua.Table);
defer guide_table.pop();

const guide = try zua.translation.decodeStruct(zua.Table, guide_table, struct {
    name: []const u8,
    version: i32,
});
```

This is also useful inside callbacks that receive a table as `self` and need to read several fields in one go rather than calling `get` repeatedly.
