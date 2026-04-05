# Passing Data In

## Struct parameters

When Lua passes a config table to your function, declare a Zig struct parameter and zua decodes the fields automatically. The struct can be named or anonymous.

```zig
const Config = struct {
    name: []const u8,
    version: i32,
};

fn printConfig(_: *Zua, config: Config) Result(.{}) {
    std.debug.print("name={s} version={d}\n", .{ config.name, config.version });
    return Result(.{}).ok(.{});
}
```

Or inline when the type is only used once:

```zig
fn printConfig(_: *Zua, config: struct {
    name: []const u8,
    version: i32,
}) Result(.{}) {
    std.debug.print("name={s} version={d}\n", .{ config.name, config.version });
    return Result(.{}).ok(.{});
}
```

Lua side in both cases:

```lua
printConfig({ name = "guided-tour", version = 1 })
```

Any struct whose fields are supported decode types works. Supported field types are `i32`, `i64`, `f32`, `f64`, `[]const u8`, `[:0]const u8`, `bool`, nested structs, and `?T` for any of the above.

## Optional and nested fields

Optional fields decode as `null` when the Lua table does not contain the key or contains `nil`. Nested struct fields decode recursively from nested Lua tables.

```zig
const Range = struct { min: f64, max: f64 };

const ScanOptions = struct {
    type: []const u8,
    eq: ?f64,
    in_range: ?Range,
};
```

This decodes both of these Lua shapes:

```lua
{ type = "f32", eq = 8.3 }
{ type = "u32", in_range = { min = 0, max = 255 } }
```

## Sum types

Lua tables that represent a sum type, where only one of several optional fields is present, do not map directly to Zig tagged unions. Decode into a flat struct with optional fields first, then convert:

```zig
const Condition = union(enum) { eq: f64, in_range: Range };

fn decodeCondition(raw: ScanOptions) !Condition {
    if (raw.eq != null and raw.in_range != null) return error.InvalidType;
    if (raw.eq) |v| return .{ .eq = v };
    if (raw.in_range) |r| return .{ .in_range = r };
    return error.InvalidType;
}
```

The two steps are intentional. The struct decode handles field extraction mechanically, and your conversion function encodes the validation rules and error messages that belong to your domain.

## Decoding a table handle manually

When you have a `Table` handle rather than a direct function argument, use `translation.decodeStruct`:

```zig
const guide_table = try globals.get("guide", zua.Table);
defer guide_table.pop();

const guide = try zua.translation.decodeStruct(zua.Table, guide_table, struct {
    name: []const u8,
    version: i32,
});
```

## Reading from eval

`Zua.eval` runs a Lua chunk and decodes return values directly into a typed Zig tuple:

```zig
const parsed = try z.eval(.{ []const u8, i32 }, "return 'hello', 42");
std.debug.print("{s} {d}\n", .{ parsed[0], parsed[1] });
```