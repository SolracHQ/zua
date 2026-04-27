# Changelog

## 0.10.1

### Added
- `Object(T).owned()` support for creating an additional reference to the same `.object` userdata handle without shallow-copying the underlying payload.
- `Fn.owned()` and `TableView.owned()` support for duplicating typed Lua handles safely without copying the wrapper payload by value.

## 0.10.0

### Breaking
- REPL syntax highlighting now uses a single `color_hook(kind, text)` callback instead of the old `color_config` and `identifier_hook` split. You can now branch directly on token kind and token text in one place.
- The REPL line editor no longer uses vendored `linenoise`; it now uses the Zig-friendly `isocline` line editor wrapper instead. This gives much better multiline input support and passes an opaque callback pointer through completion/highlight hooks so the REPL can forward allocator/IO and other host state from Zig.

### Added
- `zua.Docs`, a Lua stub generator for editor and language-server support when exposing Zig APIs to script authors.
- metadata documentation helpers: `withName`, `withDescription`, and `withAttribDescriptions`.
- `Native.ArgInfo` and wrapper-level `withDescriptions(...)` so exported functions and methods can carry parameter names and descriptions into generated stubs.
- generated files emit `---@meta _`, preserve optional types as `TYPE?`, document `VarArgs` as `---@param ...`, and emit `---@alias` for tagged unions and string-backed enums.
- `State.setGlobals(ctx, .{ ... })` for filling the globals table from a module-like anonymous struct literal.
- `Docs.generateModule(allocator, module, name)` for direct stub generation from module-like literal shape.
- shared library support for host modules via `State.libState(L, allocator, io, suffix)` and dynamic module loading from Lua.
- REPL stack trace support so runtime errors can include Lua traceback information in interactive sessions.
- A stable `Completer` abstraction for REPL completion hooks, decoupling the public API from the underlying line-editing library internals.
- live Lua runtime completion in the REPL for globals, field names, methods, and chained expressions.
  This is intentionally not a LuaS integration; LuaS did not fit the REPL session model cleanly, was hard to synchronize, and added too much configuration and latency. The new runtime completion system is simpler and more effective for interactive REPL use.

## 0.9.0

I will use this version to add more comptime checks and improve message in current ones for better UX.

### Breaking
- `Mapper.Encoder.pushValue(ctx, value)` now returns `!void` instead of `void`. Pushing long slices to Lua can now fail if the slice length exceeds Lua's maximum table size, making error handling necessary in all call sites.
- `Table.set(ctx, key, value)` now returns `!void` instead of `void` because it delegates to `pushValue` which can now fail.
- `EncodeHook(T, ProxyType)` signature changed: hooks now have explicit error handling in their return type. The hook may now return `!?ProxyType`, allowing failures during the encode transformation.
- `EncodeHook` `ProxyType` parameter can now be the same type as the input `T`, enabling value transformation and filtering via the optional `?` escape hatch. If the hook returns `null`, the default encoding path is used; if it returns an error, encoding fails; if it returns a non-null value, that value is pushed to Lua.

### Added
- Debug-mode metadata validation now catches misspelled `ZUA_META` constants during `getMetaType` evaluation.
- Improved comptime and runtime error reporting for decode and encode paths.
- Lua 5.4 is no longer vendored under `vendor/lua`. It is now pulled as a Zig package dependency from [SolracHQ/lua](https://github.com/SolracHQ/lua), a fork of upstream Lua with a `build.zig` added. I will try to keep the fork updated when new Lua versions come out.

## 0.8.0

### Breaking
- `Context.allocator()` was removed in favor of `Context.arena()` for scratch allocations and `Context.heap()` for persistent state allocations.
- `DecodeHook` signatures now return `anyerror!?T` instead of `anyerror!T`, allowing hooks to return `null` and continue the normal decode path for inputs that only need special handling in specific cases.

### Fixed
- Fixed handle ownership promotion for `Table`, `Function`, and `Userdata`: `takeOwnership()` now releases the original stack-owned handle after creating the registry reference. This prevents leaked Lua stack slots and avoids crashes when many handles are promoted, such as unfiltered `lumem:scan()` results.

### Added
- `ctx.arena()` exposes the call-local arena allocator for temporary allocations that live only for the duration of the current Lua callback.
- `ctx.heap()` exposes the persistent state allocator for values that must outlive the current call.
- Moved `Primitive` from `Mapper.Decoder` into `Mapper` so primitive types are available to both decoding and encoding paths.
- Replaced the vague `ZuaFn` public interface with explicit `NativeFn` and `Closure` wrapper constructors. `ZuaFn` conflated callback wrapping and user-facing closure/error-handling APIs, while `Native` now clearly refers to Zig native callback wrappers and `Closure` refers to wrapped callbacks with captured state.
- Added support for encoding and decoding `Primitive` values directly.
- Added `zua.Meta.List(T, getElements, methods)` for list-like userdata backed by generated indexing, length, and iterator helpers.
- Updated `mise.toml` to use Zig `0.16.0` from the stable release channel.

## 0.7.2

### Fixed
- Correctly encode registry-owned `Table`, `Function`, and `Userdata` handles by pushing them from the Lua registry with `lua.rawGetI` instead of treating the registry reference as a stack index.
- Support object userdata types that declare a custom `__index` alongside named methods by generating a combined `__index` trampoline that dispatches regular method names first and falls back to the custom handler.

## 0.7.1

### Added
- `Function.create(state, callback)` helper for pushing a native Zig callback or pre-wrapped `ZuaFn` wrapper as a raw Lua function handle.
- `Userdata.create(state, size)` helper for allocating raw full userdata and returning a stack-owned `zua.Userdata` handle.
- `zua.Fn(ins, outs).create(ctx, callback)` now validates callback parameter and return shapes at compile time using `ZuaFn` metadata.
- `Object(T)` now rejects function types and requires `T` to use `.object` strategy metadata.

## 0.7.0

### Breaking

- `Result` type removed entirely. Callbacks now return plain `!T` error unions.
- Decode hooks now receive `*Context` as first parameter and return `!T` instead of `anyerror!Result(T)`.
- Encode hooks now receive `*Context` as first parameter: `fn (*Context, T) ProxyType`.
- `pushValue` now takes `*Context` instead of `*Zua`.
- `strEnum()` encode/decode hook signatures updated to match the new conventions.
- `Zua` is removed/renamed to `State`; the old execution helpers `Zua.exec`, `Zua.eval`, `Zua.execFile`, and `Zua.evalFile` are no longer available.
- REPL-specific helpers such as `checkChunk`, `canLoadAsExpression`, `loadChunk`, and `callLoadedChunk` were removed from `State` and are now part of the dedicated REPL API.
- `Zua` no longer carries an arena field. All scratch allocation goes through `Context`.
- `State.createTable` and `State.tableFrom` were removed. Use `Table.create(z, ...)` and `Table.from(z, ...)` instead.
- `Table.pop()` renamed to `Table.release()`, with updated semantics to handle both stack-owned and registry-owned tables.

### Added
- Closure support via `zua.Meta.Capture(T, opts)` strategy and `ZuaFn.newClosure(fn, initial, config)`. The captured struct is stored as userdata in upvalue 1 of the Lua C closure; a `*T` pointer is injected into every call. Each `newClosure` push allocates an independent copy of the initial value. `__gc` is supported for cleanup of owned resources.
- New `lua.pushCClosure` and `lua.upvalueIndex` wrappers exposing `lua_pushcclosure` and `lua_upvalueindex`.
- `VarArgs` type: declare as the last callback parameter to capture all remaining Lua arguments as `[]Primitive`. Exported from `zua` as `zua.VarArgs`.
- `Primitive` union gains a `.nil` variant representing Lua `nil` and absent values, allowing custom decode hooks to fully handle optional and nil inputs.
- `decodeValue(ctx, prim, T)` is now the primary primitive-based decoding entry point and owns optional handling: `.nil` returns `null` for `?T` or fails with a typed error otherwise.
- `decodeAt(ctx, index, T)` is the stack-index entry point; it builds a `Primitive` and delegates to `decodeValue`.
- `buildPrimitive` is now `pub`, enabling decode hooks to inspect raw Lua stack values before dispatching.
- New `Executor` API for running Lua code: `Executor.execute` and `Executor.eval` with `Config`-based source selection.
- New REPL API in `zua.exec.repl` for interactive execution, with per-evaluation `Context` lifetimes and optional completion/welcome message hooks.
- Embedded `zua.Repl` interactive REPL support, including configurable prompt/continuation text, command history, completion callbacks, custom lexer identifier hooks, and ANSI syntax highlighting.
- REPL now also exposes line editing, multi-line editing, persistent history file support, and tab completion powered by `linenoise`.
- `Handlers.takeOwnership()` and `Handlers.release()` utilities for recursively promoting and releasing nested `Table`, `Function`, `Userdata`, and `TableView` handles in structs, unions, slices, arrays, and optionals.
- `Executor.err` and `Executor.stack_trace` fields for retained error and traceback values.
- `Config.stack_trace` ownership semantics are explicit: `.owned` allocates traceback data from the state allocator and must be freed manually, while `.onArena` remains owned by the current `Context`.
- `Context` passed through all translation helpers and trampolines, replacing the ad-hoc arena on `Zua`.
- `Primitive` union now includes a `.function` variant for borrowed function handles.
- `pushValue` now encodes raw Zig function types and pre-wrapped `ZuaFn` values as Lua callables, making `globals.set(&ctx, name, fn)` work directly.
- Added `zua.Fn(ins, outs)`, a typed callback wrapper for storing Lua callbacks in Zig values and returning them through Lua metadata.
- Added `zua.TableView(T)`, a typed table-backed view for mutable Lua tables that synchronizes a decoded typed copy back into the original table.
- `ZuaFn.new` unifies `ZuaFn.from` and `ZuaFn.pure` into a single wrapper that infers context usage from the function signature.
- `ctx.fail`, `ctx.failTyped`, `ctx.failWithFmt`, `ctx.failWithFmtTyped` for propagating Lua-facing errors with `try`.
- `zua.Meta.getMeta(T)` is now the canonical metadata lookup path for type translation.
- Metadata internals now store optional `encode_hook` and `decode_hook`, making custom hooks opt-in and simpler to reason about.
- Added raw `Userdata` handles for full userdata values, and typed object wrappers via `Object(T)` to safely represent `.object` strategy values as lightweight Lua userdata handles, preserving identity and enabling nested object fields

## 0.6.0

### Added

- Unified `Result` into a single tuple-backed implementation for single, multi, and zero return values.
- `Result.asOption` returns the successful value as an optional, or null on failure.
- `Result.mapErr` casts an error result to a different result type.

### Changed

- `Result(T)` now normalizes internally to the same tuple form as `Result(.{T})`.
- Temporary callback allocations now live in `z.arena` and are discarded after `pushValues`.

### Breaking

- Removed `Result.owned` and `Result.deinit`. Use `z.arena` for temporaries that do not outlive the callback.

## 0.5.1

### Added

- Added Lua 5.4 source code directly into the repository under `vendor/lua` to simplify building from source without external dependencies.

## 0.5.0

### Breaking

- `Table.get(key, T)` now returns `ParseError!Result(T)` instead of `ParseError!T`.
  Decode errors are wrapped in the Result's `.failure` field, allowing graceful error handling
  via `.failure` or panic semantics via `.unwrap()`.
- `Zua.eval()` and `Zua.evalFile()` now return `Result(ParseResult(types))` instead of
  `ParseResult(types)`, preserving error messages from decode hooks.
- Decode hook signatures changed: hooks now receive `Primitive` union (wrapping all Lua types)
  and return `anyerror!Result(T)` to provide custom error messages.
- `parse_err_fmt` now receives `{s}` placeholder populated with the actual error message
  (either from decode hook failure or "invalid arguments" for parse errors).

### Added

- `Table.has(key)` method to check key existence without triggering decoding, returning `bool`.
- `Result(T).unwrap()` on both SingleResult and MultiResult: returns the value on success or
  prints error message and calls `std.process.exit(1)` on failure (Rust-like panic semantics).
- `Function(...)` parameter type for receiving Lua functions as callback parameters.
  Enables passing callbacks from Lua into Zig, storing them via `.takeOwnership()`,
  invoking them with `.call()`, and cleaning up with `.release()`.
- `pushValue` now handles pointer-to-array types `*const [N]T`, converting to slices for cleaner
  APIs when passing constant arrays of custom types from Zig to Lua.
- Three-tier handle ownership model for Table and Function:
  1. **Borrowed**: temporary stack values valid only during callback
  2. **Stack-owned**: returned from `Table.create()` / `globals()`, require `.pop()`
  3. **Registry-owned**: created via `.takeOwnership()`, require `.release()`

## 0.4.2

### Added

- `Result(T).owned(value)` now supports single-return pointer values in addition to strings.
  Slices are released with `allocator.free` and single-item pointers with `allocator.destroy`
  after the callback returns. This makes APIs like `Result([]T)` practical when the outer
  container is allocated with `z.allocator`.

### Fixed

- `translation.pushValue` now handles slices of `.object` types correctly instead of tripping
  compile-time errors from unrelated pointer branches during generic instantiation.
- `Zua.checkChunk` no longer calls `std.mem.span` on sentinel-terminated slices.

## 0.4.1

### Added

- Tagged union support: `union(enum)` types now decode and encode directly
  without manual flat-struct boilerplate. Use `zua.Meta.Table`, `zua.Meta.Object`,
  or `zua.Meta.Ptr` on a tagged union the same as on a struct. For `.table`
  strategy, Lua passes a single-key table selecting the active variant; zua
  decodes whichever field is present and returns `error.InvalidType` if zero or
  more than one field is set. Untagged unions default to `.object`.

## 0.4.0

### Added

- `ZUA_META` builder API for centralized type metadata: `meta.Object()`, `meta.Table()`, `meta.Ptr()`, `meta.strEnum()`
- `.withEncode()` and `.withDecode()` builder methods for custom encode/decode hooks on `ZUA_META`
- `ZuaFnErrorConfig.parse_err_hook` to customize error messages when Lua argument parsing fails
- Automatic detection and reuse of pre-wrapped ZuaFn methods in metatables (check for `__IsZuaFn` marker)
- `zua.Meta` becomes the single source of truth for all type metadata queries

### Changed

- Removed old magic markers: `ZUA_TRANSLATION_STRATEGY`, `ZUA_ENCODE_CUSTOM_HOOK`, `ZUA_DECODE_CUSTOM_HOOK`, `ZUA_METHODS`
- Types may now declare `pub const ZUA_META = zua.Meta.<strategy>(...)` with appropriate builder chain to customize behavior; defaults to `.table` if not declared
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
- `Table.create` creates a new table and returns an absolute-indexed handle
- `Table.from` converts a Zig struct or array literal into a Lua table recursively
- `Zua.exec` runs a Lua chunk for side effects
- `Zua.eval` runs a Lua chunk and decodes the returned values into a comptime-typed tuple
- `Table.set` and `Table.get` dispatch on comptime type, no raw stack indexes in calling code
- `Table.setFn` registers a Zig callback, generating the C trampoline internally via `wrap`
- `Table.setLightUserdata` and `Table.getLightUserdata` for threading host state through the VM
- `Table.setMetatable` attaches a metatable to a table handle
- `Table.pop` removes the table from the stack when done
- `Args.parse` decodes typed callback arguments into a comptime tuple in one call
- `Result(.{ ... })` declares callback return types and carries typed success values or Lua-facing failures
- `Result.errStatic` and `Result.errOwned` carry callback failures without exposing `lua_error` directly
- The `wrap` trampoline delays `lua_error` until after the Zig callback has fully returned, keeping `defer` safe inside callbacks
- Supported types for `parse` and `set`: `i32`, `i64`, `f32`, `f64`, `[]const u8`, `bool`, `zua.Table`