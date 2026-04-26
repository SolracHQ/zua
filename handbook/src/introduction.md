# Introduction

zua is a Zig toolkit for Lua interop. The goal is simple: write ordinary Zig functions and types, pass them to Lua, and have them just work without thinking about the stack.

The Lua C API is powerful but exhausting. After enough files full of `lua_push`, `lua_pop`, and `lua_settop`, adding a new function means reconstructing a mental model of stack positions that resets every time you step away. zua replaces that with a pipeline: Zig values encode to Lua values, Lua values decode back to Zig types, and the mapping is resolved at compile time from the type itself. No registration calls, no runtime reflection. A function is just another value: zua wraps it and generates the encode and decode paths for it at comptime, so you pass values back and forth between Zig and Lua and the boundary mostly disappears.

Stack management, longjmp safety, arena allocation inside callbacks, all handled automatically.

The hooks matter. Encoding and decoding are open to customization at any point without touching the library. If a type needs special handling on the way in or out, you declare it once and the rest of the pipeline picks it up. Same for metamethods, `__gc`, `__tostring`, custom error formats. You customize behavior by describing it, not by patching code.

This is a personal project. It started because I nearly abandoned a Lua-scripted tool of mine after the binding layer grew into several files of push and pop calls that I could no longer follow a week after writing them. Every feature in zua exists because I faced a real pain without it. If you hit a bug or a missing use case, please open an issue, I will be glad to help.

## What this handbook covers

Each chapter adds capability on top of the previous one. You can read straight through or jump to the chapter that covers what you need. Most chapters are self-contained: concepts are repeated where necessary so you can start wherever you like.

### Setup
`State`, `Context`, `Executor`, running Lua code from Zig.

### First function
arguments, return values, error messages.

### Context and arena
the call allocator, string lifetimes, when to use the arena vs the state allocator.

### Errors
`ctx.fail`, `ctx.failWithFmt`, catching errors from Zig, stack tracebacks.

### Structured data
structs as tables, optional fields, nested structs, building tables from Zig.

### Strategies
`.table`, `.object`, `.ptr`, `zua.Meta.List` for sequence-like userdata with `__index`, `__len`, and iteration, what each one is for and when to use which.

### Methods and ZUA_META
attaching functions to types, `self` variants, metamethods.

### Lifecycle and __gc
when Lua collects objects and how to clean up owned resources.

### Encode and decode hooks
custom type conversions, `strEnum`, `withEncode`, `withDecode`.

### Handles and ownership
borrowed, stack-owned, registry-owned, what each means in practice.

### Table and Function handles
`zua.Table`, `zua.Function`, when you hold vs borrow.

### Object handles
`zua.Object(T)`, `zua.Userdata`, `Handlers.takeOwnership`.

### Closures
`Meta.Capture`, `Native.closure`, partial application with captured Lua callbacks.

### VarArgs and Primitive
variadic functions, inspecting raw Lua values, `decodeValue`.

### Stub generation
`zua.Docs`, `generateModule`, editor stubs for script authors.

### Shared libraries
`State.libState`, writing `luaopen_*` exports, loading with `require`.

### REPL
the built-in interactive shell, history, completion, syntax highlighting.

> [!NOTE]
> The handbook assumes you know what a pointer is, what comptime means, and what an allocator does. On the Lua side, basic syntax and data types are enough. Concepts specific to zua are explained as they come up.