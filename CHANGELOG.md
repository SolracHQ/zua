# Changelog

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
- `zua.err(.{ ... }, ...)` allocates callback error messages with the right return shape
- The `wrap` trampoline delays `lua_error` until after the Zig callback has fully returned, keeping `defer` safe inside callbacks
- Supported types for `parse` and `set`: `i32`, `i64`, `f32`, `f64`, `[]const u8`, `bool`, `zua.Table`