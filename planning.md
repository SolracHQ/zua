# Planning

Future work that is still not implemented.

After struggling to port the current memscript API onto zua, it became clear that I rely on a few recurring binding patterns that are still awkward to express with the current surface area. These are the main items planned for the next feature release, likely v0.2.0.

## Table decode ergonomics

Memscript uses option tables heavily for APIs like `proc.list`, `process.regions`, `process.scan`, and `entries.rescan`.
Zua now has optional positional args, but table decoding is still too shallow for that style of API.

- Add optional field support to `Table.get` and `Table.getStruct` so missing fields can decode into `?T` instead of always failing with `MissingField`.
- Add recursive table-to-struct decoding so nested option tables like `{ in_range = { min = 1, max = 5 } }` can decode directly into Zig structs.
- Add support for decoding tagged unions / sum types from tables where the API naturally accepts one of several condition shapes.

## Table iteration helpers

Memscript methods like `entries.rescan` need to accept a Lua array of entry tables, walk it in Zig, and rebuild typed host values.
Zua can read one field at a time, but it does not yet have a good wrapper-level API for iterating Lua list tables.

- Add helpers to iterate Lua array tables without dropping to the raw C API for `rawLen`, indexed reads, and stack cleanup.
- Add a way to decode `[]T` or `std.ArrayList(T)` from a Lua array table when each element is a scalar or struct-like table.

## Chunk and file execution helpers

Memscript's current CLI and REPL need more than `exec` and `eval` on inline source strings.

- Add `execFile` / `evalFile` helpers so script execution does not need to drop to raw `lua.loadFile`.
- Add a lower-level `loadChunk` wrapper that returns a handle to a compiled function without immediately calling it.

## Explicit chunk environment support

The memscript REPL keeps a persistent workspace by rebinding `_ENV` on loaded chunks.
That currently requires raw Lua upvalue manipulation.

- Add a wrapper API to bind an environment table to a loaded chunk/function.
- Add a REPL-oriented helper path for "try as expression, else run as statement" without rebuilding that control flow around raw Lua stack operations.