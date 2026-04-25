# Introduction

zua is a Zig library for embedding Lua. The boundary between the two languages is meant to mostly disappear: you write ordinary Zig functions, register them, and they work from Lua. Structs decode from tables, errors propagate as Lua messages, and `defer` stays safe inside callbacks. None of that requires touching the Lua C API.

When something goes wrong, you know why. Type mismatches name the expected type and what arrived instead. Custom encode and decode hooks give you full control over how any type crosses the boundary, in both directions, without abandoning the automatic path for everything else. I really love hooks because they let you customize behavior in a clean and powerful way.

The handbook builds from the ground up. Setup, then a first function, then richer types, then the parts you reach for when simple isn't enough: object lifecycle, closures, holding Lua callbacks from Zig, the built-in REPL. Each chapter adds one thing and shows it working.

## What this handbook covers

Each chapter adds capability on top of the previous one. You can read straight through or jump to the chapter that covers what you need. Most chapters are self-contained: concepts are repeated where necessary so you can go straight to what you need without reading everything before it.

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
- **Stub generation** - `zua.Docs`, `generateModule`, editor stubs for script authors.
- **Shared libraries** - `State.libState`, writing `luaopen_*` exports, loading with `require`.
- **REPL** - the built-in interactive shell, history, completion, syntax highlighting.

> [!NOTE]
> The handbook assumes you know what a pointer is, what comptime means, and what an allocator does. On the Lua side, basic syntax and data types are enough. Concepts specific to zua are explained as they come up.