# zua (Zig + Lua)

zua lets you write Zig and call it from Lua.

You define functions and types in Zig, register them with the VM, and zua handles the boundary. No stack indexes. No push/pop accounting. No longjmp surprises. You write Zig, Lua calls it.

Born from [memscript](https://github.com/solracHQ/memscript), where the original Lua binding code was a wall of manual stack arithmetic that was impossible to read a week after writing it.

This project mostly exists to simplify my work on memscript, which means I only add features as memscript needs them. If you want to use it for something else and find something missing, open an issue or a PR.

## How it works

A `Zua` instance owns the Lua state. You register Zig functions and data on it. Lua scripts call them. zua generates the C trampoline that sits between Lua and your Zig code, decodes arguments from the Lua stack into typed Zig values, and converts your return values back. The `longjmp` that `lua_error` uses only fires after your Zig function has fully returned, so `defer` works the way you expect.

## What it looks like

Define a Zig function with typed parameters:

```zig
fn add(a: i32, b: i32) Result(i32) {
    return Result(i32).ok(a + b);
}
```

Register it and run a script:

```zig
const z = try Zua.init(allocator);
defer z.deinit();

const globals = z.globals();
defer globals.pop();

globals.setFn("add", ZuaFn.pure(add, "add expects (i32, i32)"));

try z.exec("print(add(1, 2))");
```

That is the whole model. The rest is details.

## Status

- `Zua` owns the Lua state and allocator, heap-allocated so its pointer is stable across callbacks.
- `ZuaFn.from` and `ZuaFn.pure` register Zig functions. Arguments are decoded directly from the function signature.
- `Result(T)` and `Result(.{ T1, T2 })` carry typed return values and Lua-facing failures back through the trampoline.
- `Table` handles wrap Lua tables with absolute stack indexes so -1 and -2 never appear in your code.
- `tableFrom` converts Zig structs, arrays, and tuples to Lua tables in one call.
- `Table.getStruct` decodes a Lua table into a typed Zig struct, with support for optional and nested fields.
- `Zua.eval` runs a Lua chunk and decodes return values directly into a typed Zig tuple.
- `registry()` and `getLightUserdata` thread hidden host state through callbacks without exposing it to Lua.

## Handbook

Worked examples and patterns live in `handbook/`. Start with `functions.md`.

## Minimal example

```zig
const z = try Zua.init(allocator);
defer z.deinit();

const globals = z.globals();
defer globals.pop();

globals.set("greeting", "hello");
globals.setFn("add", ZuaFn.pure(add, "add expects (i32, i32)"));

try z.exec("message = greeting .. ', world'");

const parsed = try z.eval(.{ []const u8, i32 }, "return message, add(1, 2)");
std.debug.print("{s} {d}\n", .{ parsed[0], parsed[1] });
```

## Installation

Add zua as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .zua = .{
        .url = "https://github.com/solracHQ/zua/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

Then in `build.zig`:

```zig
const zua = b.dependency("zua", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zua", zua.module("zua"));
```

Requires Lua 5.4 headers and a system Lua library.

On Debian/Ubuntu:

```sh
apt install liblua5.4-dev
```

On Fedora:

```sh
dnf install lua-devel
```

## License

MIT, see [LICENSE](LICENSE).