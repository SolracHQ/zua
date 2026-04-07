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
    const current = (try self.get("count", i32)).unwrap();
    const next = current + delta;
    self.set("count", next);
    return Result(i32).ok(next);
}

const counter = z.tableFrom(.{ .count = 0 });
defer counter.pop();
counter.setFn("increment", ZuaFn.from(increment, .{
    .parse_err_fmt = "counter:increment expects (i32)",
}));
globals.set("counter", counter);
```

```lua
counter:increment(5)
```

## Checking for key existence

Use `table.has()` to check if a key exists before calling `get`:

```zig
fn readOptional(_: *Zua, self: Table) Result(i32) {
    if (!self.has("value")) {
        return Result(i32).ok(0);  // default
    }
    return (try self.get("value", i32)).unwrap();
}
```

This is useful for optional fields or when you want to handle missing keys differently than type errors.

## Decoding a table you already have

When you have a `Table` handle rather than a direct function argument, call its `get` method multiple times or use structure decoding:

```zig
const guide_table = try globals.get("guide", zua.Table);
defer guide_table.pop();

const name = (try guide_table.get("name", []const u8)).unwrap();
const version = (try guide_table.get("version", i32)).unwrap();
```

For one-shot decoding of many fields, use `decodeStruct`:

```zig
const guide = try zua.translation.decodeStruct(zua.Table, struct {
    name: []const u8,
    version: i32,
});
```

The `.unwrap()` method returns the value if successful, or panics with the error message if the field is missing or has the wrong type. For production code that needs to handle errors gracefully, check the `.failure` field:

```zig
const result = try guide_table.get("version", i32);
if (result.failure) |failure| {
    const err_msg = switch (failure) {
        .static_message => |msg| msg,
        .owned_message => |msg| msg,
    };
    // handle error with err_msg...
} else {
    const version = result.value;
    // use version...
}
```

## Handle Ownership

Both `Table` and `Function` handles have three ownership modes that determine their lifetime and cleanup responsibility:

### Borrowed handles

Temporary handles created from Lua stack values within a callback. Valid only for the duration of the callback. No cleanup needed.

```zig
fn processTable(z: *Zua, table: Table) Result(.{}) {
    // table is borrowed - stack remains owned by Lua
    const value = (try table.get("key", i32)).unwrap();
    return Result(.{}).ok(.{});
    // do not pop() - Lua manages cleanup
}
```

### Stack-owned handles

Returned from wrapper APIs like `createTable()` or `globals()`. The handle owns the stack position until you call `.pop()`. Only valid until popped or replaced by another stack operation.

```zig
const table = z.createTable(0, 3);
defer table.pop();  // must pop before returning
table.set("x", 10);
```

### Registry-owned handles

Persistent references anchored in the Lua registry, valid across callback invocations. Created by calling `.takeOwnership()` on a borrowed or stack-owned handle. You are responsible for calling `.release()` to clean up.

```zig
var stored_table: ?zua.OwnedTable = null;

fn storeTable(z: *Zua, table: Table) Result(.{}) {
    // table is borrowed - take ownership to persist it
    stored_table = try table.takeOwnership();
    return Result(.{}).ok(.{});
}

fn accessStored(_: *Zua) Result(i32) {
    if (stored_table) |table| {
        const value = (try table.get("count", i32)).unwrap();
        return Result(i32).ok(value);
    }
    return Result(i32).errStatic("no table stored");
}

fn cleanup() void {
    if (stored_table) |table| {
        table.release();
        stored_table = null;
    }
}
```

The registry reference is freed immediately on `.release()`; the table value remains in Lua only if other references exist.
