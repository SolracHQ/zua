# Planning

Unfinished work only.


## Table iteration

- Add helpers to iterate Lua array tables without dropping to the raw C API for `rawLen`, indexed reads, and stack cleanup.
- Add a way to decode `[]T` or `std.ArrayList(T)` from a Lua array table when each element is a scalar or struct-like table.

## Chunk loading

- Add `execFile` / `evalFile` helpers so script execution does not need to drop to raw `lua.loadFile`.
- Add a lower-level `loadChunk` wrapper that returns a handle to a compiled function without immediately calling it.

## Chunk environments

- Add a wrapper API to bind an environment table to a loaded chunk/function.
- Add a REPL-oriented helper path for "try as expression, else run as statement" without rebuilding that control flow around raw Lua stack operations.