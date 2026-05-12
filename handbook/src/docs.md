# Docs generation

When you expose a Zig API to Lua script writers, the runtime experience is good immediately, but the editor experience is not. The language server does not know what globals exist, what methods they have, or what parameter types they expect. The `zua.Docs` generator solves that by emitting Lua stub files you can point your Lua LSP at.

The goal is simple: describe the API once in Zig, generate a `.lua` file, and let completion, hover, and signature help work for your script authors.

## Where this runs

The generator is a normal Zig utility. It does not need a Lua `State`, a `Context`, or a running VM. You use it from ordinary Zig code, usually in a small tool or an example program that writes the stub file as part of your build workflow.

That keeps stub generation separate from the runtime API itself. You describe the Lua-facing surface in metadata and wrappers, then generate editor stubs from those declarations offline.

## Basic flow

Create a `Docs` generator, add the functions and types you want to expose, then call `generate()`:

```zig
var generator = zua.Docs.init(allocator);
defer generator.deinit();

try generator.add(make_vector);
try generator.add(new_counter);
try generator.add(Vector2);
try generator.add(Counter);

const stubs = try generator.generate();
```

In a real program the surrounding context usually looks like this:

```zig
const std = @import("std");
const zua = @import("zua");

pub fn main(init: std.process.Init) !void {
    var generator = zua.Docs.init(init.gpa);
    defer generator.deinit();

    try generator.add(make_vector);
    try generator.add(new_counter);
    try generator.add(Vector2);
    try generator.add(Counter);

    const stubs = try generator.generate();

    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(init.io, "types/zua-api.lua", .{});
    defer file.close(init.io);

    var write_buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&write_buffer);
    const writer = &file_writer.interface;

    try writer.writeAll(stubs);
    try writer.flush();
}
```

`add` accepts three kinds of input:

- a plain Zig function, which is documented as if it were wrapped with `zua.Native.new(function, .{}, .{})`
- a native wrapper value created with `zua.Native.new(...)`
- a Zig type with `ZUA_META`

The generator walks the same kind of type information the encoder uses. Table strategy types expand into fields and methods. Object strategy types stay opaque and only expose methods. Typed wrappers such as `zua.Handlers.Typed.Object(T)` and `zua.Handlers.Typed.TableView(T)` are treated as transparent references to `T`.

## Naming exported functions

The generator uses the wrapper's `name` field for top-level functions. That matters when the exported Lua global name is different from the Zig function name.

This is common with constructors. In Zig you might write a function called `newCounter`, but expose it to Lua as `new_counter` or `Counter`. The type name and the function name are different concepts, so set them explicitly on the wrapper you pass to `Docs.add`.

```zig
const new_counter = zua.Native.new(newCounter, .{}, .{
    .name = "new_counter",
    .description = "Construct a new Counter object.",
});

try generator.add(new_counter);
try generator.add(Counter);
```

## Adding parameter descriptions

For functions, parameter names and descriptions come from the `args` field in `DocOptions`.

```zig
const make_vector = zua.Native.new(makeVector, .{}, .{
    .name = "make_vector",
    .description = "Construct a new Vector2 value.",
    .args = &.{
        .{ .name = "x", .description = "Initial horizontal coordinate." },
        .{ .name = "y", .description = "Initial vertical coordinate." },
    },
});
```

Each entry provides `name` (displayed as the parameter name in the stub) and an optional `description` (appears as a trailing comment in the generated `---@param` line).

This is necessary because Zig's function type info does not carry parameter names in a form the generator can read at comptime.

## Adding field descriptions

For `.table` types, field descriptions come from the `field_descriptions` field in `MetaOptions`:

```zig
const Vector2 = struct {
    pub const ZUA_META = zua.Meta.Table(Vector2, .{
        .scale = zua.Native.new(scale, .{}, .{
            .args = &.{
                .{ .name = "factor", .description = "Scalar multiplier applied to both coordinates." },
            },
        }),
    }, .{
        .name = "Vector2",
        .description = "Simple table-backed 2D vector.",
        .field_descriptions = .{
            .x = "Horizontal coordinate.",
            .y = "Vertical coordinate.",
        },
    });

    x: f64,
    y: f64,
};
```

Only `.table` strategy types support attribute descriptions, because only tables expose public fields to Lua.

## What gets generated

For the example above, `generate()` emits Lua annotations like these:

```lua
---@meta _

---@class Counter
local Counter = {}

---@param amount integer # Amount added to the counter.
function Counter:increment(amount) end

---@param x number # Initial horizontal coordinate.
---@param y number # Initial vertical coordinate.
---@return Vector2
function make_vector(x, y) end

---@class Vector2
---@field x number # Horizontal coordinate.
---@field y number # Vertical coordinate.
local Vector2 = {}
```

The `---@meta _` header at the top marks the file as a declaration-only stub that should not be loaded as a regular module.

Optional types appear as `TYPE?` in the generated output. A function parameter of type `?i32` becomes `integer?` in the stub. A function that returns `?Vector2` is annotated `---@return Vector2?`.

`VarArgs` parameters are emitted as `---@param ... any`. If you supply an `ArgInfo` entry with the name `"..."`, the description is included on that line as well.

## Operator annotations

When a type declares metamethods like `__add`, `__tostring`, or `__call` in its `ZUA_META`, the generator emits `---@operator` lines on the class stub. These tell the language server what operators the type supports. The operator name, parameter type, and return type are all pulled from the metamethod's signature, so there is nothing extra to wire up.

## Tagged union variants

Tagged unions generate `---@alias` declarations instead of class stubs. Each variant becomes either an inline shape or its own class, depending on whether a `.name` is provided.

### Simple variants (no name)

When a variant has only a `.description` and no `.name`, the type is inlined directly in the alias:

```zig
const Condition = union(enum) {
    eq: i32,
    in_range: struct { min: i32, max: i32 },

    pub const ZUA_META = zua.Meta.Table(@This(), .{}, .{
        .name = "Condition",
        .description = "Tagged union selector.",
        .variants = .{
            .eq = .{
                .description = "Exact match against a single value.",
            },
            .in_range = .{
                .name = "ConditionRange",
                .description = "Match values within a range.",
                .field_descriptions = .{
                    .min = "Minimum bound of the range.",
                    .max = "Maximum bound of the range.",
                },
            },
        },
    });
};
```

The `eq` variant has no `.name`, so its type is inlined. The `in_range` variant has `.name = "ConditionRange"`, so it becomes a separate class and the alias points to it:

```lua
---@class ConditionRange
---@field min integer # Minimum bound of the range.
---@field max integer # Maximum bound of the range.
-- Match values within a range.
local ConditionRange = {}

---@alias Condition
---| { eq = integer } # Exact match against a single value.
---| { in_range = ConditionRange } # Match values within a range.
```

### Per-variant field descriptions

When a variant's type is a struct (either a named type or inline), its fields can be documented with `.field_descriptions` inside the variant's info block. The descriptions appear on the variant class's `---@field` lines:

```zig
.in_range = .{
    .name = "ConditionRange",
    .description = "Match values within a range.",
    .field_descriptions = .{
        .min = "Minimum bound of the range.",
        .max = "Maximum bound of the range.",
    },
},
```

### String-backed enums

For `strEnum` types, the alias lists the string literals directly:

```lua
---@alias Priority "low" | "normal" | "high"
```

## Docs hooks

Tagged unions always generate an `---@alias` based on their Zig variant layout. When the same union is decoded from strings at runtime (via a decode hook), the generated alias exposes internal variant types instead of the actual string values Lua accepts.

To fix that, attach a docs hook with `.withDocs(handler)`. The hook receives the `*Docs` generator and pushes entries directly into its lists, replacing the default collection:

```zig
const ConcreteOs = enum { windows, linux, macos, bsd };
const OsFamily = enum { unix_like, bsd_based };

const Os = union(enum) {
    Concrete: ConcreteOs,
    Family: OsFamily,

    pub const ZUA_META = zua.Meta.Table(Os, .{}, .{
        .name = "Os",
        .description = "Operating system selector. Accepted as strings like \"linux\", \"unix-like\", or \"bsd-based\".",
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

Now the stub shows clean string literals instead of the internal union layout:

```lua
---@alias Os
---| 'windows'
---| 'linux'
---| 'macos'
---| 'bsd'
---| 'unix-like'
---| 'bsd-based'
```

The hook replaces the automatic collection entirely. Internal Zig types referenced by the union variants are not pulled into the output. If you attach a docs hook, it always runs; there is no fallback to the default.

See the [Hooks chapter](./hooks.md#docs-hooks) for the full API reference and more examples.

## Module shorthand

Most modules expose a single value that the encoder pushes. For these, `generateModule` is the quickest path to a working stub file:

```zig
const stubs = try zua.Docs.generateModule(allocator, MyModule{}, "my_module");
```

The output has `---@meta my_module` at the top, the type and function stubs in the middle, and `return MyModule` at the end. LuaLS sees that header and knows this file describes what `require("my_module")` returns.

```lua
---@meta my_module

---@class MyModule
local MyModule = {}

return MyModule
```

When the module bundles function-valued fields under a single type name, the same function works. The fields get full `---@param` signatures instead of hiding behind opaque `---@field name function` lines:

```zig
const Vecmath = struct {
    pub const ZUA_META = zua.Meta.Table(Vecmath, .{}, .{
        .name = "vecmath",
    });
    vec2: @TypeOf(vec2_fn) = vec2_fn,
    lerp: @TypeOf(lerp_fn) = lerp_fn,
};

const stubs = try zua.Docs.generateModule(allocator, Vecmath{}, "vecmath");
```

```lua
---@meta vecmath

---@class vecmath
local vecmath = {}

---@return Vec2
function vecmath.vec2(x, y) end

---@return Vec2
function vecmath.lerp(a, b, t) end

return vecmath
```

For the REPL and script-executor case where the API is a single global, call `generate()` after registering the global as a binding:

```zig
var docs = zua.Docs.init(allocator);
defer docs.deinit();
try docs.addBinding("my_api", MyApi{});
const stubs = try docs.generate();
```

```lua
---@meta _

---@class MyApi
local MyApi = {}

my_api = MyApi
```

The `---@meta _` header makes all types and functions visible workspace-wide. The runtime already has the global registered, so no `require` call is needed. The stub file just tells the editor what that global looks like.

## Writing the stub file

`generate()` and `generateModule` both return the full Lua source as a string. Write it to a file that your editor indexes, for example `types/zua-api.lua` or `.luarc-generated/zua.lua`.

The explicit `flush()` in the full example above matters because the writer is buffered.

How you hook that into the build is up to you. Some projects generate the file during `zig build`. Others keep a small tool or example program and regenerate it when the scripting API changes. Shared libraries can expose a `docs()` function that script authors call once to write the stub themselves.