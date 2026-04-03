# zua (Zig + Lua)

zua is a small Zig wrapper over the Lua C API, born from the mess of writing [memscript](https://github.com/solracHQ/memscript).

The Lua C API is not bad. It is just easy to get wrong. Stack indexes drift, push/pop balance breaks in non-obvious ways, and `lua_error` calls `longjmp` which silently skips any cleanup you set up with `defer`. When you come back to the code after a week you have to reconstruct the whole stack discipline in your head before you can change anything.

zua puts a thin layer over all of that. Tables get absolute indexes so -1 and -2 never appear in your binding code. Callbacks are plain Zig functions that receive typed arguments and return a typed `Result`. The `longjmp` only fires after your function has fully returned, so `defer` works the way you expect.

It is not a binding generator. It does not serialize Zig structs automatically or manage coroutines. Everything you can do with the raw C API you can still do, you just do not have to think about the stack while you do it.

This project mostly exists to simplify my work on memscript, that means that I will only add features as I need them for memscript. If you want to use it for something else and find a missing feature, open an issue or a PR and I will take a look when I can.

## Status

- `Zua` owns the Lua state and the allocator, heap-allocated so its pointer is stable inside callbacks.
- `Table` handles wrap stack positions with absolute indexes.
- `tableFrom` converts plain Zig structs, arrays, and tuples into Lua tables recursively.
- `Args.parse` decodes typed callback arguments in one call.
- `Result(.{T})` carries typed return values and an optional error through the trampoline without exposing `longjmp` to calling code.
- `zua.err` allocates a formatted error message and hands ownership to the trampoline.
- `zua.eval` runs a chunk and decodes return values directly into a typed tuple with no intermediate handle.
- `registry()` and `getLightUserdata` cover the common pattern of threading host state through callbacks.

## Usage

```zig
const z = try zua.Zua.init(allocator);
defer z.deinit();

const globals = z.globals();
defer globals.pop();

globals.set("greeting", "hello");
globals.setFn("add", add);

try z.exec("message = greeting .. ', world'");

const parsed = try z.eval(.{ []const u8, i32 }, "return message, add(1, 2)");
std.debug.print("{s} {d}\n", .{ parsed[0], parsed[1] });
```

Callbacks declare their return types in the signature. Arguments are parsed in one line, errors are returned without touching the Lua stack directly.

```zig
fn add(z: *Zua, args: Args) Result(.{i32}) {
    const parsed = args.parse(.{ i32, i32 }) catch return z.err(.{i32}, "add expects (i32, i32)", .{});
    return Result(.{i32}).ok(.{parsed[0] + parsed[1]});
}
```

Methods work the same way. The first argument from `:` syntax is the receiver table, decoded like any other argument.

```zig
fn increment(z: *Zua, args: Args) Result(.{i32}) {
    const parsed = args.parse(.{ Table, i32 }) catch return z.err(.{i32}, "counter:increment expects (self, i32)", .{});
    const next = (parsed[0].get("count", i32) catch return z.err(.{i32}, "counter.count missing", .{})) + parsed[1];
    parsed[0].set("count", next);
    return Result(.{i32}).ok(.{next});
}
```

Use `owned` instead of `ok` when returning allocated strings. The trampoline frees them after pushing, so you do not track the allocation yourself.

```zig
fn joinPath(z: *Zua, args: Args) Result(.{[]const u8}) {
    const parsed = args.parse(.{ []const u8, []const u8, []const u8 }) catch return z.err(.{[]const u8}, "join_path expects (string, string, string)", .{});
    const joined = std.fmt.allocPrint(z.allocator, "{s}/{s}/{s}", .{ parsed[0], parsed[1], parsed[2] }) catch return z.err(.{[]const u8}, "out of memory", .{});
    return Result(.{[]const u8}).owned(z.allocator, .{joined});
}
```

Light userdata is the cleanest way to pass host state into callbacks without exposing it as a normal Lua value.

```zig
zua.registry().setLightUserdata("app_state", &app_state);

fn nextTicket(z: *Zua, args: Args) Result(.{i32}) {
    _ = args;
    const registry = z.registry();
    defer registry.pop();
    const app = registry.getLightUserdata("app_state", AppState) catch return z.err(.{i32}, "app state missing", .{});
    app.next_ticket += 1;
    return z.Result(.{i32}).ok(.{app.next_ticket - 1});
}
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