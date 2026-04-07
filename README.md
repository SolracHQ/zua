# zua (Zig + Lua)

zua lets you write Zig and call it from Lua. No stack indexes. No push/pop accounting. No longjmp surprises.

```zig
fn add(a: i32, b: i32) Result(i32) {
    return Result(i32).ok(a + b);
}

globals.setFn("add", ZuaFn.pure(add, .{
    .parse_err_fmt = "add expects (i32, i32), but got {s}",
}));
```

```lua
print(add(1, 2))    -- 3
print(add("oops"))  -- error: add expects (i32, i32), but got string
```

That is the whole model. You declare typed Zig functions, zua handles the boundary, Lua calls them. The argument decoding, return value encoding, and safe `lua_error` dispatch all happen automatically.

zua uses comptime heavily. Type dispatch, struct decoding, metatable generation from declared methods - it all happens at compile time. If you like libraries that do the hard work for you but stay explicit at the call site, this should feel natural.

Born from [lumem](https://github.com/solracHQ/lumem), where hand-written binding code was impossible to maintain. Features get added when lumem or other real projects need them.

## Handbook

The handbook covers everything: functions, passing structured data, exposing Zig types with methods and metamethods, host state, running Lua from Zig.

```sh
cd handbook
mdbook serve
```

Then open http://localhost:3000.

BTW, if you are looking at main branch, the handbook is published in github actions and available in the [docs](https://solrachq.github.io/zua/).

## Philosophy

zua adds features when memscript or other projects need them. The goal is not maximum feature coverage, but a tight integration that works well for real use cases. If something is missing, open an issue or PR.

I am not super experienced in Zig, so bugs and edge cases may exist. If you find something broken or unexpected, please open an issue. I cannot test all the comptime paths, so reports help a lot.

## Memory management note

When you call `Result.owned(value)`, the value must be allocated with `z.allocator`. If it comes from a different allocator, cleanup will fail. Stick with `z.allocator` for anything you hand to zua.

## Platforms

I develop on Linux (Fedora and Ubuntu WSL). Both are well-tested. Windows and macOS might work, but I do not actively support them. If you hit issues on other platforms, let me know.

## Installation

### Using zig fetch (recommended)

```sh
zig fetch --save git+https://github.com/SolracHQ/zua
```

```zig
const zua = b.dependency("zua", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zua", zua.module("zua"));
```

### Pinning a specific version

Add zua to `build.zig.zon` with a specific commit:

```zig
.dependencies = .{
    .zua = .{
        .url = "https://github.com/solracHQ/zua/archive/<commit>.tar.gz",
        .hash = "<hash>",
    },
},
```

### System requirements

zua now includes Lua 5.4 as a pinned Git submodule, so a system Lua development package is no longer required or supported for building from source.

When cloning the repository, initialize the submodule:

```sh
git clone --recurse-submodules https://github.com/SolracHQ/zua.git
```

Or after cloning:

```sh
git submodule update --init --recursive
```

## License

MIT, see [LICENSE](LICENSE).