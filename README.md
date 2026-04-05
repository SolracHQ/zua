# zua (Zig + Lua)

zua lets you write Zig and call it from Lua, seamlessly. No stack indexes. No push/pop accounting. No longjmp surprises. You define typed Zig functions, register them, and Lua calls them. That's it.

The goal is to eliminate manual Lua crafting. Instead of wrestling with the C API, you declare what you want in Zig and zua handles the boundary.

Born from [memscript](https://github.com/solracHQ/memscript), where binding code was impossible to maintain. This project adds features as memscript needs them. It's practical, not comprehensive.

## How it works

A `Zua` instance owns the Lua state. You register Zig functions and data. Lua scripts call them. zua generates the C trampoline between Lua and your code:

- Decodes Lua arguments into typed Zig values before your function sees them
- Converts your Zig return values back into Lua values
- Fires `lua_error` only after your Zig function returns completely, so `defer` is safe

The result is clean Zig code that doesn't think about Lua mechanics.

## Examples

### Type-safe functions

Lua arguments match your Zig function signature. No checking. No casting. No mistakes.

```zig
fn add(a: i32, b: i32) Result(i32) {
    return Result(i32).ok(a + b);
}

// Register it
globals.setFn("add", ZuaFn.pure(add, .{
    .parse_error = "add expects (i32, i32)",
}));
```

Now Lua just calls it:

```lua
print(add(1, 2))  -- 3
print(add("oops"))  -- error: add expects (i32, i32)
```

See [functions.md](handbook/src/functions.md) for more patterns.

### Struct parameters and return values

Pass Lua tables to Zig as typed structs. Return Zig data as tables.

```zig
const Config = struct {
    name: []const u8,
    version: i32,
};

fn printConfig(_: *Zua, config: Config) Result(.{}) {
    std.debug.print("{s} v{d}\n", .{ config.name, config.version });
    return Result(.{}).ok(.{});
}
```

Lua passes a table:

```lua
printConfig({ name = "myapp", version = 1 })
```

See [passing-data-in.md](handbook/src/passing-data-in.md) and [passing-data-out.md](handbook/src/passing-data-out.md).

### Methods and types

Expose Zig types with methods and metamethods. Choose how they map: immutable Lua tables, mutable userdata objects, or opaque pointers.

```zig
const Vector = struct {
    pub const ZUA_TRANSLATION_STRATEGY: zua.translation.Strategy = .object;
    pub const ZUA_METHODS = .{
        .length = length,
        .__add = add,
        .__tostring = toString,
    };

    x: f64,
    y: f64,

    fn length(self: *Vector) Result(f64) {
        const len = std.math.sqrt(self.x * self.x + self.y * self.y);
        return Result(f64).ok(len);
    }

    fn add(z: *Zua, a: *Vector, b: *Vector) Result(Vector) {
        return Result(Vector).ok(.{ .x = a.x + b.x, .y = a.y + b.y });
    }

    fn toString(z: *Zua, self: *Vector) Result([]const u8) {
        const msg = try std.fmt.allocPrint(z.allocator, "Vector({d}, {d})", .{self.x, self.y});
        return Result([]const u8).owned(msg);
    }
};
```

Lua uses it naturally:

```lua
local v1 = makeVector(3, 4)
print(v1:length())  -- 5
print(v1 + makeVector(1, 0))  -- Vector(4, 4)
```

See [exposing-zig-types.md](handbook/src/exposing-zig-types.md) and [userdata-objects.zig](example/userdata_objects.zig).

### Custom hooks for type translation

Enums encode as integers by default, but you can customize how any type translates to and from Lua.

```zig
const Status = enum(u8) {
    idle = 0,
    running = 1,
    stopped = 2,

    pub const ZUA_ENCODE_CUSTOM_HOOK = encodeStatusAsString;

    fn encodeStatusAsString(status: Status) []const u8 {
        return switch (status) {
            .idle => "idle",
            .running => "running",
            .stopped => "stopped",
        };
    }
};

fn getStatus(_: *Zua) Result(Status) {
    return Result(Status).ok(.running);
}
```

Lua receives a string instead of a number:

```lua
local status = getStatus()
print(status)  -- "running"
```

Decode hooks let you accept multiple Lua value types and convert them:

```zig
const Address = struct {
    value: u64,

    pub const ZUA_DECODE_CUSTOM_HOOK = decodeAddressHook;

    fn decodeAddressHook(z: *Zua, index: zua.lua.StackIndex, kind: zua.lua.Type) !Address {
        return switch (kind) {
            .number => Address{ .value = @intCast(zua.lua.toInteger(z.state, index) orelse 0) },
            .userdata => Address{ .value = // ... extract from userdata ... },
            else => error.InvalidType,
        };
    }
};
```

Now `testAddress` accepts both numbers and handles:

```lua
testAddress(0xdeadbeef)  -- works
testAddress(myHandle)    -- also works
```

See [custom-hooks.md](handbook/src/custom-hooks.md) and [custom_hooks.zig](example/custom_hooks.zig).

### Memory management

Decoded slices are allocated and cleaned up automatically. Owned strings from Lua are tracked. No manual freeing after callbacks return.

```zig
fn processItems(_: *Zua, items: []const u8) Result(i32) {
    // items is a slice allocated from z.allocator
    // it's freed after this function returns
    return Result(i32).ok(@intCast(items.len));
}
```

> **Warning**: When you call `Result.owned(value)`, the value must be allocated with `z.allocator`. If it comes from a different allocator, the cleanup will fail. Stick with `z.allocator` for simplicity.

### Error handling

Return errors from Zig, they become Lua errors automatically.

```zig
fn readFile(z: *Zua, path: []const u8) !Result([]const u8) {
    const contents = try std.fs.cwd().readFileAlloc(z.allocator, path, 1024 * 1024);
    return Result([]const u8).owned(contents);
}
```

If the file doesn't exist, Lua gets an error with your message.

### Running Lua code

You have full control over when and how Lua code executes. Use `exec` for side effects, `eval` for typed return values, and `execFile` for loading scripts.

```zig
// Execute code for side effects
try z.exec("print('hello')");

// Evaluate code and decode return values
const result = try z.eval(i32, "return 1 + 2");
std.debug.print("{d}\n", .{result});  // prints: 3

// Load and execute a script file
try z.execFile("script.lua");

// Evaluate a file and decode results
const data = try z.evalFile(.{ []const u8, i32 }, "config.lua");
```

Errors in Lua code become Zig errors. Catch them or propagate with `try`:

```zig
z.exec("bad lua") catch |err| {
    std.debug.print("Error: {}\n", .{err});
};
```

For interactive use, the library includes REPL helpers: `checkChunk` detects incomplete input, `loadChunk` loads without executing, `callLoadedChunk` executes.

See [running-lua.md](handbook/src/running-lua.md) for patterns like building Lua REPLs and working with traceback information.

## Handbook

Start with [functions.md](handbook/src/functions.md) for worked examples. All chapters are in `handbook/src/`.

The handbook is built with [mdbook](https://rust-lang.github.io/mdBook/). To read it in your browser:

```sh
cd handbook
mdbook serve
```

Then open http://localhost:3000. Changes to chapter files update live.

## Philosophy

zua adds features when memscript or other projects need them. The goal is not maximum feature coverage, but rather a tight integration that works well for my use cases. If you need something that's missing, open an issue or PR and I'll take a look when I have time.

> Note: I'm not super experienced in Zig, so bugs and edge cases may exist. If you find something broken or unexpected, please open an issue. I can't test all the comptime paths, so reports help a lot.

## Platforms

I develop on Linux (Fedora and Ubuntu WSL). Both are well-tested. Windows and macOS might work, but I don't actively support them. If you hit issues on other platforms, let me know.

## Installation

### Using zig fetch (recommended for latest)

The easiest way to get the latest version:

```sh
cd your-project
zig fetch --save git+https://github.com/SolracHQ/zua
```

Then in `build.zig`:

```zig
const zua = b.dependency("zua", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zua", zua.module("zua"));
```

### Manual version pinning

Or add zua to `build.zig.zon` with a specific commit:

```zig
.dependencies = .{
    .zua = .{
        .url = "https://github.com/solracHQ/zua/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

### System requirements

You need Lua 5.4 headers and library.

On Fedora:
```sh
dnf install lua-devel
```

On Debian/Ubuntu:
```sh
apt install liblua5.4-dev
```

## License

MIT, see [LICENSE](LICENSE).