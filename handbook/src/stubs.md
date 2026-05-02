# Stub generation

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

- a plain Zig function, which is documented as if it were wrapped with `zua.Native.new(function, .{})`
- a native wrapper value created with `zua.Native.new(...)`
- a Zig type with `ZUA_META`

The generator walks the same kind of type information the encoder uses. Table strategy types expand into fields and methods. Object strategy types stay opaque and only expose methods. Typed wrappers such as `zua.Object(T)` and `zua.TableView(T)` are treated as transparent references to `T`.

## Naming exported functions

The generator uses the wrapper's `name` field for top-level functions. That matters when the exported Lua global name is different from the Zig function name.

This is common with constructors. In Zig you might write a function called `newCounter`, but expose it to Lua as `new_counter` or `Counter`. The type name and the function name are different concepts, so set them explicitly on the wrapper you pass to `Docs.add`.

```zig
const new_counter = zua.Native.new(newCounter, .{})
    .withName("new_counter")
    .withDescription("Construct a new Counter object.");

try generator.add(new_counter);
try generator.add(Counter);
```

## Adding parameter descriptions

For functions, parameter names and descriptions come from `withDescriptions`.

```zig
const make_vector = zua.Native.new(makeVector, .{}).withDescriptions(&.{
    .{ .name = "x", .description = "Initial horizontal coordinate." },
    .{ .name = "y", .description = "Initial vertical coordinate." },
}).withName("make_vector").withDescription("Construct a new Vector2 value.");
```

Each entry provides `name` (displayed as the parameter name in the stub) and an optional `description` (appears as a trailing comment in the generated `---@param` line).

This is necessary because Zig's function type info does not carry parameter names in a form the generator can read at comptime.

## Adding field descriptions

For `.table` types, field descriptions come from `withAttribDescriptions` on `ZUA_META`:

```zig
const Vector2 = struct {
    pub const ZUA_META = zua.Meta.Table(Vector2, .{
        .scale = zua.Native.new(scale, .{}).withDescriptions(&.{
            .{ .name = "factor", .description = "Scalar multiplier applied to both coordinates." },
        }),
    })
        .withDescription("Simple table-backed 2D vector.")
        .withAttribDescriptions(.{
            .x = "Horizontal coordinate.",
            .y = "Vertical coordinate.",
        })
        .withName("Vector2");

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

Tagged unions and string-backed enums generate `---@alias` declarations instead of class stubs. For a tagged union `Condition` with variants `eq` and `in_range`, the generator emits an alias listing each variant shape. For a `strEnum` type, the alias lists the string literals directly:

```lua
---@alias Priority "low" | "normal" | "high"
```

## Module shorthand

When your API is already grouped into a module-like struct literal, you can skip the `Docs` builder entirely and call `generateModule` directly:

```zig
const stubs = try zua.Docs.generateModule(allocator, module, "mymod");
```

The first argument is a plain allocator, not the call arena. The second is the module struct. The third is the module name, which appears in the `---@meta` header:

```lua
---@meta mymod
```

Pass `null` for the name to emit `---@meta _` instead.

Inside a Lua callback, use `ctx.arena()` as the allocator if the stub string only needs to live for the duration of that call:

```zig
fn docs(ctx: *zua.Context) ![]const u8 {
    return zua.Docs.generateModule(ctx.arena(), module, "mymod");
}
```

This is the pattern used in the `vecmath` shared library example: a `docs` function exposed to Lua generates and returns the stub text on demand.

## Writing the stub file

`generate()` and `generateModule` both return the full Lua source as a string. Write it to a file that your editor indexes, for example `types/zua-api.lua` or `.luarc-generated/zua.lua`.

The explicit `flush()` in the full example above matters because the writer is buffered.

How you hook that into the build is up to you. Some projects generate the file during `zig build`. Others keep a small tool or example program and regenerate it when the scripting API changes. Shared libraries can expose a `docs()` function that script authors call once to write the stub themselves.