# Contributing to zua

This is a quick guide for those that want to contribute. Its a small kinda personal library so I'm not that rigurous, just please try to follow the style here when you open a PR.

## Module structure

The public API lives in `api.zig` files inside each module.

Submodules are part of the public API but are either too big to fit in `api.zig` or have their own domain and need a separate namespace. They are re-exported directly from `api.zig`, for example:

```zig
pub const Decoder = @import("decode/api.zig");
pub const Encoder = @import("encode.zig");
```

Internals are implementation details that may change without notice. They are aggregated through an `internals.zig` file:

```zig
pub const Internals = @import("internals.zig");
```

```
module/
├── api.zig         - ALL public API
├── internals.zig   - Aggregates utilities (Assertions, Helpers, etc.)
├── helpers.zig     - Implementation detail, not public
├── submodule/
│   └── api.zig     - Submodule with its own public API
└── ...
```

Users access internals as `Module.Internals.Helper`. That signals "you can use this but it may change without notice."

Wire it into `root.zig` (the entry point for `@import("zua")`). If it belongs in the common path add a flat re-export to `prelude.zig` too.

A module with one type and no sub-modules is a single file named lowercase, no directory:

```
zua/
├── state.zig       - State type (single-file module)
├── context.zig     - Context type (single-file module)
├── executor.zig    - Executor type (single-file module)
```

## Imports

All imports go at the top of the file. That lets you see in a single sight what a file depends on. Avoid imports inside functions or type declarations unless strictly necessary. If you must do it, document why:

```zig
const SomeType = if (builtin.target.os.tag == .linux) struct {
    // can't import at module level without pulling linux-specific deps
    const linux = @import("linux.zig");
};
```

 The only case that justifies an inline import is conditional compilation that would pull platform-specific dependencies unconditionally at module level. Circular dependencies are not a valid reason since `const` declarations are lazily evaluated.

## Module naming convention

Intrinsics and external libraries (`std`, `builtin`, `lua`) use lowercase names at the top of the file, before any other imports.

```zig
const std = @import("std");         // intrinsic, lowercase
const builtin = @import("builtin"); // intrinsic, lowercase
const lua = @import(".../lua.zig"); // external C binding, lowercase
const isocline = @import("...");    // external C binding, lowercase
const zua = @import("zua");         // our library name, lowercase
```

Everything else is PascalCase:

```zig
const Context = @import("../context.zig");  // internal, PascalCase
const Helpers = @import("helpers.zig");     // internal, PascalCase
```

Lowercase means something I do not control. PascalCase means something internal I create.

## Documentation style

Doc comments should wrap at around 80 characters. Not a hard limit, just a recomendation since the wrap looks bad on small laptop screens (buy a good screen guys). Code has no width limit, just what `zig fmt` imposes.

Respect visibility level in doc comments. Do not leak internals in public API docs (do not mention which internal functions you use). In internal functions do not spill implementation details (nobody cares if you use two pointers or `.removeAt` to filter, only that this filters). That kind of comment can go inside the function body and only if it is not obvious from the code. In Zig most of the time it is obvious. Doc comments are a soft contract: you are telling the user "I do this in this way", and that means changing internals becomes breaking the contract.

### Module-level doc (`//!` at top of file)

Say what the module does, what you need to use it, and any invariants. Add a usage example if the API needs setup steps before it works. Do not list every function. LSP already shows those.

```
//! How a Zig type maps to its Lua representation.
//!
//! Attach a `pub const ZUA_SHAPE` to your type using one of the
//! constructors in this module. Each constructor picks a strategy:
//! userdata with identity and methods, a plain table, a light userdata
//! pointer, or a callable closure.
```

### Type-level doc

The purpose of the type, the lifetime invariants (who owns it, when it becomes invalid), the creation pre-conditions if any, the destroy pre-conditions if any, and the effect on Lua lifecycle if any.

```
/// Owns the Lua VM state and metatable cache. Valid until `deinit` is
/// called. Created with `init(allocator, io)` or `libState(L, ...)`.
/// Pass `&state` to `Context.init` to create a short-lived call context.
pub const State = @This();
```

### Fields documentation

What the field stores, any constraints on valid values, who owns the memory if it is a pointer or slice.

```
/// Maximum number of history entries. -1 uses the isocline default (200).
history_max: c_long = -1,
```

### Functions documentation

What the function does, what it receives (if not obvious from the signature), any pre-conditions that must hold before calling, any side effects (especially Lua side effects like stack changes), whether it is comptime or runtime, static or method. Private functions can have lighter docs or none if they are short helpers.

```
/// Reads a value from the Lua stack and pops the slot.
///
/// Any handler types in the returned value are converted to owned
/// (registry) handles before the stack slot is removed. Call
/// `.release()` on them when done.
pub fn pop(ctx: *Context, comptime T: type) !T {
```

## Changelog

Every significant change gets an entry in `CHANGELOG.md` under `## Unreleased` during development. Significant means it changes what a user sees or does: new features, behavior changes, bug fixes, deprecations. Internal refactors that do not touch the public surface do not need one.

At PR time the `## Unreleased` heading becomes the new version number depending on what changed and what the previous version was. Use the right category:

- `### Added` - new features, new public API, new examples
- `### Changed` - behavior changes to existing (released) API
- `### Fixed` - bug fixes
- `### Breaking` - backwards-incompatible changes
- `### Removed` - deleted public API

## What to do depending on the change

The handbook at `handbook/` is the primary source of truth. If a user reads it they should see your feature exists and understand what it does. Update it on every change that touches the public surface.

All code changes (everything except documentation) need the version bumped in `build.zig.zon`. The CD pipeline tags the release based on that file.

Prefer examples over isolated tests. An example serves three purposes: it teaches the user how to use zua, it becomes part of the book so readers can check real running code, and it verifies the feature compiles. Only write standalone tests when the behavior is hard to demonstrate in an example (edge cases, internal invariants).

### New public module

1. Create the module directory with `api.zig` as entry point.
2. Create `internals.zig` if it has internal sub-modules.
3. Wire it into `root.zig`.
4. Optionally update `prelude.zig`.
5. Modify an example in `example/` in the corresponding category. If there is an example of the same category, modify it instead of adding a new one.
6. Update the handbook.
7. Add a entry in the changelog.

### New submodule inside an existing module

1. Create the submodule. Use a directory with `api.zig` if it has internals, or `{name}.zig` as a single file if it is simple.
2. Re-export it from the parent module `api.zig`.
3. Follow the Internals pattern if it has internals.
4. Update the handbook if the public surface changed.
5. Add a entry in the changelog.

### Addition to an existing public API

1. Add the feature to the right `api.zig`, otherwise this does not apply hehe.
2. Modify an example in `example/` in the corresponding category.
3. Update the handbook.
4. Add a entry in the changelog.

### Internal helper

1. Add it to the appropriate file under the module.
2. Wire it into `internals.zig` if it needs to be aggregated.
3. If the helper is hard to demonstrate in an example (edge case, internal invariant), write a test under `src/test/`.
4. Add a entry in the changelog if significant.

### Fix

1. If the bug can be shown in an example, modify or add one. Otherwise write a test under `src/test/` that reproduces it.
2. Apply the fix.
3. Add a entry in the changelog.

### Refactor with no behavior change

1. Keep tests passing.
2. If extracting helpers, add tests for the extracted code.

### Restructure or rename

1. Update all import paths across the codebase.
2. Update `root.zig` and `prelude.zig`.
3. Verify build and tests.

### New example

1. Create the file under `example/`.
2. Wire it into `build.zig` if needed.

### Remove deprecated API

This only applies when we reach 1.0. Before that we just change things.

1. Mark with compile error pointing to the replacement.
2. Update examples.
3. Update the handbook.
4. Add a entry under `Breaking` or `Removed`.

### Improve documentation

1. Update the handbook at `handbook/` or add doc comments following the style guide above.
2. Make sure `mdbook build` runs without errors under `handbook/`.

### Improve error messages

1. Change the message.
2. Update any tests that assert on the old message.

### Bump a dependency

1. Update `build.zig.zon`.
2. Update `mise.toml` if zig version.
3. Verify everything builds.
