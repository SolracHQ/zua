# Introduction

zua is a Zig library for embedding Lua. You write Zig, Lua calls it.

The Lua C API works, but it requires you to think about the stack constantly. You push arguments, check types, pop return values, and make sure nothing blows up if the indices are off. It is doable but it makes every binding function look the same, and that sameness is not helping you, it is just noise.

zua takes a different approach. You write typed Zig functions and register them. The argument decoding and return value encoding happen automatically at the boundary. Your functions do not know they are being called from Lua.

```zig
fn add(a: i32, b: i32) Result(i32) {
    return Result(i32).ok(a + b);
}

globals.setFn("add", ZuaFn.pure(add, .{
    .parse_err_fmt = "add expects (i32, i32)",
}));
```

```lua
print(add(1, 2))     -- 3
print(add("oops"))   -- error: add expects (i32, i32)
```

That is the whole idea. The comptime machinery handles the boundary so the Zig side stays clean.

zua uses comptime heavily. Type-based dispatch, automatic struct decoding, metatable generation from declared methods, all of it happens at compile time with no runtime overhead. If you like libraries that do the hard work for you but stay explicit at the call site, this should feel natural.

A few things zua does not do: it does not wrap every Lua feature, it does not try to be a general-purpose Lua embedding toolkit. It adds things when they are needed for real projects. If something is missing, open an issue.


