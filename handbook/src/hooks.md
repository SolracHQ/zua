# Encode and decode hooks

By default, zua encodes and decodes types according to their strategy. An encode hook lets you change what Lua sees when a value is pushed. A decode hook lets you accept multiple Lua value types for a single Zig type. The two hooks are independent; you can have one without the other.

> [!NOTE]
> TBH I really love hooks. They make both your life and my life easier by letting you extend functionality without hardcoding behavior. Adding hooks to encoder and decoder was one of my happiest ideas.

## Encode hooks

An encode hook transforms a value before it is pushed to Lua. The classic use is encoding an enum as a string:

```zig
const Status = enum(u8) {
    idle    = 0,
    running = 1,
    stopped = 2,

    pub const ZUA_META = zua.Meta.Table(Status, .{}, .{})
        .withEncode([]const u8, encodeAsString);

    fn encodeAsString(_: *zua.Context, status: Status) !?[]const u8 {
        return switch (status) {
            .idle    => "idle",
            .running => "running",
            .stopped => "stopped",
        };
    }
};
```

Now any function that returns `Status` pushes a Lua string instead of an integer. The hook returns `!?ProxyType`: returning `null` skips encoding and falls back to the default path, returning an error fails encoding. `ProxyType` may be the same type as `T`; use `null` as the escape hatch to avoid infinite recursion when the hook only needs to transform some values.

## Decode hooks

A decode hook lets a type accept multiple Lua value types. The hook receives a `Primitive` union that wraps the actual Lua value:

```zig
const Address = struct {
    pub const ZUA_META = zua.Meta.Object(Address, .{
        .value = getValue,
    }, .{}).withDecode(decodeHook);

    inner: u64,

    pub fn getValue(self: *Address) u64 { return self.inner; }

    fn decodeHook(ctx: *zua.Context, prim: zua.Mapper.Decoder.Primitive) !?Address {
        return switch (prim) {
            .integer  => |n| .{ .inner = @intCast(n) },
            .string   => |s| blk: {
                const digits = if (std.mem.startsWith(u8, s, "0x")) s[2..] else s;
                break :blk .{ .inner = std.fmt.parseInt(u64, digits, 16)
                    catch return ctx.failTyped(?Address, "invalid hex address") };
            },
            .userdata => null, // allow the default object decode path for existing Address handles
            else => ctx.failTyped(?Address, "expected integer, hex string, or Address"),
        };
    }
};
```

Now any function that takes `Address` by value accepts integers, hex strings, and existing handles from Lua without any changes to those functions. The hook only handles the special integer/string cases; returning `null` for userdata lets the normal object decode path handle existing handles.

> [!IMPORTANT]
> The decode hook fires when the type is decoded as a plain value `T`. It does not fire for `*T` receivers in `.object` methods; those extract the raw userdata pointer directly. So `fn method(self: *Address)` always receives the Lua userdata handle, while `fn f(addr: Address)` goes through the hook and accepts all the forms the hook handles.

### Docs hooks

A decode hook changes what values a type accepts from Lua. The stub generator does not know about your decode hook. It walks the Zig type layout and generates annotations based on struct fields and union variants. When those do not match the string values or table shapes your decode hook accepts, the generated stubs lie to the language server.

That is where a docs hook comes in. It is the documentation counterpart of a decode hook. You attach it with `.withDocs(handler)` on the same `ZUA_META` that has the decode hook, and it replaces the default stub output with entries you push into the generator's lists.

The classic case is a tagged union that decodes from strings but would otherwise spill its internal variants:

```zig
const ConcreteOs = enum { windows, linux, macos, bsd };
const OsFamily = enum { unix_like, bsd_based };

const Os = union(enum) {
    Concrete: ConcreteOs,
    Family: OsFamily,

    pub const ZUA_META = zua.Meta.Table(Os, .{}, .{
        .name = "Os",
        .description = "Operating system selector.",
    }).withDecode(decode).withDocs(osDocs);

    fn decode(ctx: *zua.Context, prim: zua.Mapper.Decoder.Primitive) !?Os {
        return switch (prim) {
            .string => |s| {
                if (std.mem.eql(u8, s, "windows")) return .{ .Concrete = .windows };
                if (std.mem.eql(u8, s, "linux")) return .{ .Concrete = .linux };
                if (std.mem.eql(u8, s, "macos")) return .{ .Concrete = .macos };
                if (std.mem.eql(u8, s, "bsd")) return .{ .Concrete = .bsd };
                if (std.mem.eql(u8, s, "unix-like")) return .{ .Family = .unix_like };
                if (std.mem.eql(u8, s, "bsd-based")) return .{ .Family = .bsd_based };
                return ctx.failTyped(?Os, "unknown os: {s}", .{s});
            },
            else => return null,
        };
    }

    fn osDocs(self: *zua.Docs) !void {
        var alias = zua.Docs.Alias{
            .name = try self.arena.allocator().dupe(u8, "Os"),
            .description = try self.arena.allocator().dupe(u8, "Operating system selector."),
            .values = .empty,
        };
        for ([_][]const u8{ "windows", "linux", "macos", "bsd", "unix-like", "bsd-based" }) |name| {
            try alias.values.append(self.arena.allocator(), .{
                .type = try std.fmt.allocPrint(self.arena.allocator(), "'{s}'", .{name}),
                .description = "",
            });
        }
        try self.aliases.append(self.arena.allocator(), alias);
    }
};
```

Without the docs hook the stub exposes `ConcreteOs` and `OsFamily`. With the hook it shows exactly what strings Lua can pass:

```lua
---@alias Os
---| 'windows'
---| 'linux'
---| 'macos'
---| 'bsd'
---| 'unix-like'
---| 'bsd-based'
```

The hook receives the `*Docs` generator and pushes entries directly into its class, alias, or table lists. It replaces the automatic collection entirely, so internal types referenced by the Zig definition are not pulled into the output.

> [!IMPORTANT]
> You can push whatever you want into the docs lists inside the hook, but make sure you add at least one alias or class with the same name you set in `ZUA_META`. Other types that reference this one will look it up by that name.

Docs hooks do not have a fallback path. If you attach one, it always runs. There is no `null` return to skip it and use the defaults. If you only need to add descriptions or customize names, use `MetaOptions` fields like `.description`, `.field_descriptions`, or `.variants` instead.

The docs hook is not limited to aliases. A table-strategy type with internal fields you want to hide from Lua tooling can push an object or table entry into the class list instead. The [Docs chapter](./docs.md#docs-hooks) shows more context around stub generation.

## Hooks are independent

Encode and decode do not need to mirror each other. Push as a string, accept as an integer. Or the other way around. You get exactly what you wire up.

## strEnum

For enums where Lua should see string names rather than integers, `Meta.strEnum` derives both encode and decode hooks automatically from the enum field names:

```zig
const Direction = enum { north, east, south, west };

pub const ZUA_META = zua.Meta.strEnum(Direction, .{}, .{});
```

```lua
local d = getDirection()  -- returns "north", "east", etc.
setDirection("east")       -- accepts the string name
```

`strEnum` is the fast path when field names are exactly what you want Lua to see. If you need different names or mixed integer/string input, use `withEncode` and `withDecode` manually.

> [!NOTE]
> `strEnum` derives hook functions from enum field names at compile time. If your field names are not valid Lua-friendly identifiers, use a manual encode hook with a `switch` statement to map them explicitly.

## The Primitive union

Decode hooks receive a `Primitive` that covers every Lua value type:

| Variant | Lua type |
|---|---|
| `.nil` | nil or absent |
| `.boolean` | boolean |
| `.integer` | integer |
| `.float` | float |
| `.string` | string |
| `.table` | table (borrowed) |
| `.function` | function (borrowed) |
| `.light_userdata` | light userdata |
| `.userdata` | full userdata (borrowed) |

`table`, `function`, and `userdata` variants hold borrowed handles valid only during the current callback. Call `.takeOwnership()` before returning if you need them to outlive the call. The [Handles and ownership](./ownership.md) chapter covers the ownership model in detail.
