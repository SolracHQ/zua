# Changelog

## 0.4.0

### Added

- `ZUA_META` builder API for centralized type metadata: `meta.Object()`, `meta.Table()`, `meta.Ptr()`, `meta.strEnum()`
- `.withEncode()` and `.withDecode()` builder methods for custom encode/decode hooks on `ZUA_META`
- `ZuaFnErrorConfig.parse_err_hook` to customize error messages when Lua argument parsing fails
- Automatic detection and reuse of pre-wrapped ZuaFn methods in metatables (check for `__IsZuaFn` marker)
- `zua.meta` becomes the single source of truth for all type metadata queries

### Changed

- Removed old magic markers: `ZUA_TRANSLATION_STRATEGY`, `ZUA_ENCODE_CUSTOM_HOOK`, `ZUA_DECODE_CUSTOM_HOOK`, `ZUA_METHODS`
- Types may now declare `pub const ZUA_META = zua.meta.<strategy>(...)` with appropriate builder chain to customize behavior; defaults to `.table` if not declared
- `translation.zig` now imports and uses metadata helpers from `meta.zig` exclusively
- Simplified internal API: centralized `strategyOf()`, `hasEncodeHook()`, `hasDecodeHook()`, `methodsOf()` in `meta.zig`

## 0.3.0

### Added

- Enum support: `.table` mode encodes/decodes enums as integers; `.object` mode wraps in userdata with metatable
- `ZUA_ENCODE_CUSTOM_HOOK` declaration on types to customize encoding (e.g., enums to strings)
- `ZUA_DECODE_CUSTOM_HOOK` declaration on types to support multiple Lua input types with low-level decoding
- Custom decode hooks enable flexible input handling: examine `lua.Type` and decode directly from stack using Lua C API functions
- Encode hook transparently converts types before pushing to Lua stack

### Changed

- `Result.owned(value)` signature simplified: removed unused `z` parameter. `Result.owned()` now only marks ownership; the value must already be allocated with `z.allocator`

## 0.2.0

### Added

- Type translation strategies: `.object` (userdata with metatable), `.zig_ptr` (light userdata pointer), and `.table` (Lua table, default)
- `ZUA_TRANSLATION_STRATEGY` declaration on types to select strategy; defaults to `.table` if not declared
- `ZUA_METHODS` struct declaration for exposing methods and metamethods on userdata and table-strategy types
- Metatable caching system: `Zua.metatable_cache` stores built metatables by type name; `Zua.getOrCreateMetatable(T)` builds and caches on first call
- Metamethods (field names starting with `__` like `__tostring`, `__index`) are placed directly on the metatable; regular methods go in the `__index` table
- `metatable.buildMetatable` constructs metatables with optional `__name` field and optional methods table
- `metatable.attachMetatable` attaches cached metatable to userdata after `lua_newuserdata`
- Full method wrapping via `ZuaFn` trampoline system; methods receive `*Zua` or `self: *T`/`self: T` as first parameter
- Callbacks decode arguments directly from the Zig function signature, including optional positional parameters via `?T`
- `Result(T)` supports single-value callback returns without the tuple wrapper ceremony
- `Table.setFn` accepts callbacks returning either `Result(...)` or `!Result(...)`
- The `wrap` trampoline converts Zig errors from `!Result(...)` callbacks into `Result.errZig(err)` automatically
- `Result.errOwned` formats and allocates owned error messages directly from `fmt` and `args`
- `Table.get` and `Table.getStruct` support optional fields like `?T`
- `Table.getStruct` supports recursive nested table decoding for struct fields
- Added `ZuaFnErrorConfig.zig_err_fmt` to customize Zig error formatting in callback wrappers
- Added `execTraceback` for Lua runtime failures with stack trace results
- Slice decoding: `[]T` types are automatically decoded from Lua array tables with automatic memory allocation
- ZuaFn callbacks track and clean up allocated slices automatically via `cleanupDecodedValues` (recursive cleanup for nested types)
- REPL support helpers: `checkChunk` detects incomplete vs complete Lua input; `canLoadAsExpression` distinguishes expressions from statements
- `loadChunk` loads Lua source without execution; `callLoadedChunk` executes a loaded chunk and leaves results on stack
- File execution helpers: `execFile`, `evalFile`, `execFileTraceback` for loading and executing Lua scripts without manual file I/O

## 0.0.1

First working version, extracted from memscript.

### Added

- `Zua.init` and `Zua.deinit` own the Lua state and allocator, heap-allocated for stable pointer identity inside callbacks
- `Zua.fromState` retrieves the `Zua` pointer from a raw `lua_State` inside C callbacks
- `Zua.globals` and `Zua.registry` return `Table` handles for the global and registry tables
- `Zua.createTable` creates a new table and returns an absolute-indexed handle
- `Zua.tableFrom` converts a Zig struct or array literal into a Lua table recursively
- `Zua.exec` runs a Lua chunk for side effects
- `Zua.eval` runs a Lua chunk and decodes the returned values into a comptime-typed tuple
- `Table.set` and `Table.get` dispatch on comptime type, no raw stack indexes in calling code
- `Table.setFn` registers a Zig callback, generating the C trampoline internally via `wrap`
- `Table.setLightUserdata` and `Table.getLightUserdata` for threading host state through the VM
- `Table.setMetatable` attaches a metatable to a table handle
- `Table.pop` removes the table from the stack when done
- `Args.parse` decodes typed callback arguments into a comptime tuple in one call
- `Result(.{ ... })` declares callback return types and carries typed success values or Lua-facing failures
- `Result.errStatic`, `Result.errOwned`, and `Result.errZig` carry callback failures without exposing `lua_error` directly
- The `wrap` trampoline delays `lua_error` until after the Zig callback has fully returned, keeping `defer` safe inside callbacks
- Supported types for `parse` and `set`: `i32`, `i64`, `f32`, `f64`, `[]const u8`, `bool`, `zua.Table`