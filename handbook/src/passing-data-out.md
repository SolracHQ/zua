# Passing Data Out

When your Zig code needs to give structured data back to Lua, use `tableFrom` for data you already have, or build a table step by step with `createTable` and `set`.

## Structs and literals

```zig
const guide = z.tableFrom(.{
    .name = "guided-tour",
    .version = 1,
    .tags = [_][]const u8{ "zig", "lua" },
});
defer guide.pop();
globals.set("guide", guide);
```

Struct fields become string keys. Arrays and slices become array-style Lua tables. Nesting works recursively.

## Step by step

```zig
const entry = z.createTable(0, 3);
defer entry.pop();

entry.set("address", "0x7fff1234");
entry.set("type", "f32");
entry.set("value", 8.3);
globals.set("entry", entry);
```

## Adding methods

Methods are Zig functions registered on a table. Lua calls them with `:` syntax, which passes the receiver table as the first argument.

```zig
fn increment(_: *Zua, self: Table, delta: i32) Result(i32) {
    const current = self.get("count", i32) catch return Result(i32).errStatic("count missing");
    const next = current + delta;
    self.set("count", next);
    return Result(i32).ok(next);
}

const counter = z.tableFrom(.{ .count = 0 });
defer counter.pop();
counter.setFn("increment", ZuaFn.from(increment, "counter:increment expects (i32)"));
globals.set("counter", counter);
```

```lua
counter:increment(5)
```

## Returning a table from a callback

Push the table as the return value using `Result(Table)`:

```zig
fn makeEntry(z: *Zua, address: []const u8, type_name: []const u8) Result(Table) {
    const t = z.createTable(0, 2);
    t.set("address", address);
    t.set("type", type_name);
    return Result(Table).ok(t);
}
```

The trampoline pushes the table value and pops the handle after.