# Introduction

zua is a Zig library for embedding Lua without the usual boilerplate. Stack management, type conversion, memory allocation inside C callbacks, using `defer` without getting burned by `longjmp`, all of that is handled automatically. You write Zig functions, register them, and they work from Lua.

```zig
fn add(a: i32, b: i32) i32 {
    return a + b;
}

globals.set(&ctx, "add", add);
```

```lua
print(add(1, 2))    -- 3
print(add("oops"))  -- error: add expects (i32, i32): string
```

Argument decoding, return value encoding, and error dispatch all happen automatically. Type mapping, struct decoding, and metatable generation all happen at compile time through Zig's comptime system, so there is no runtime overhead from the binding layer.

zua is designed to be flexible. This handbook goes from a simple `add` function all the way to opaque objects with methods, complex state with `__gc` cleanup, closures with captured Lua callbacks, and a built-in interactive REPL, without touching the raw Lua C API once.

## What this handbook covers

Each chapter adds capability on top of the previous one. You can read straight through or jump to the chapter that covers what you need.

- **Setup** - `State`, `Context`, `Executor`, running Lua code from Zig.
- **First function** - arguments, return values, error messages.
- **Context and arena** - the call allocator, string lifetimes, when to use the arena vs the state allocator.
- **Errors** - `ctx.fail`, `ctx.failWithFmt`, catching errors from Zig, stack tracebacks.
- **Structured data** - structs as tables, optional fields, nested structs, building tables from Zig.
- **Strategies** - `.table`, `.object`, `.ptr`, what each one is for and when to use which.
- **Methods and ZUA_META** - attaching functions to types, `self` variants, metamethods.
- **Lifecycle and __gc** - when Lua collects objects and how to clean up owned resources.
- **Encode and decode hooks** - custom type conversions, `strEnum`, `withEncode`, `withDecode`.
- **Handles and ownership** - borrowed, stack-owned, registry-owned, what each means in practice.
- **Table and Function handles** - `zua.Table`, `zua.Function`, when you hold vs borrow.
- **Object handles** - `zua.Object(T)`, `zua.Userdata`, `Handlers.takeOwnership`.
- **Closures** - `Meta.Capture`, `ZuaFn.newClosure`, partial application with captured Lua callbacks.
- **VarArgs and Primitive** - variadic functions, inspecting raw Lua values, `decodeValue`.
- **REPL** - the built-in interactive shell, history, completion, syntax highlighting.

> [!NOTE]
> The handbook assumes you know what a pointer is, what comptime means, and what an allocator does. On the Lua side, basic syntax and data types are enough. Concepts specific to zua are explained as they come up.