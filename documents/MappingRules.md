# Mapping Rules

This file is a reference with the rules of what can be represented and what cannot when passing data between Lua and Zig.

## Quick-reference conversion table

The tables below summarise every supported direction. "Borrowed" means the handle is valid only for the duration of the current callback. "→" means the column on the left is what you write in Zig; the cell is what Lua sees.

### Primitives and scalars

| Zig type | Lua type (encoded) | Zig type (decoded from Lua) | Notes |
|---|---|---|---|
| `bool` | boolean | `bool` | |
| `i8`..`i64` | integer | `i8`..`i64` | Range-checked; returns error on overflow |
| `u8`..`u63` | integer | `u8`..`u63` | Range-checked |
| `u64` and larger | float (lossy) | — | Prefer `.object` for values above `u63` |
| `f32`, `f64` | float | `f32`, `f64` | Lua integer coerces to float on decode |
| `[]const u8` | string | `[]const u8` | Decoded slice points into Lua-owned memory |
| `[:0]const u8` | string | `[:0]const u8` | Sentinel-terminated; same lifetime rules |
| `*const [N]u8` | string | — | Encode only; decoded as `[]const u8` |
| `?T` | nil (if null) or `T` | `?T` | Decodes absent or nil Lua values as `null` |

### Structs and composites

| Zig type | Strategy | Lua type (encoded) | Lua type (decoded from) | Notes |
|---|---|---|---|---|
| `struct { … }` | `.table` (default) | table | table | Fields become string-keyed table entries |
| `struct { … }` | `.object` | userdata + metatable | userdata | Identity-preserving; GC-managed by Lua |
| `struct { … }` | `.ptr` | light userdata | light userdata | Raw pointer; Lua holds no ownership |
| `struct { … }` | `.capture` | userdata in upvalue 1 | — | Used only by `ZuaFn.newClosure`; not a standalone parameter type |
| `[]T` | (element strategy) | array table | array table | Each element encoded/decoded by its own strategy |
| `[N]T` | (element strategy) | array table | — | Encode only; decoded as `[]T` slices |

### Enums

| Zig type | Strategy / hook | Lua type (encoded) | Lua type (decoded from) |
|---|---|---|---|
| `enum` | `.table` (default) | integer | integer |
| `enum` | `Meta.strEnum` | string | string |

### Tagged unions

| Zig type | Strategy | Lua type (encoded) | Lua type (decoded from) | Notes |
|---|---|---|---|---|
| `union(enum)` | `.table` (default) | single-key table `{variant = value}` | single-key table | Errors if zero or more than one key is set |
| `union(enum)` | `.object` | userdata + metatable | userdata | Entire union stored as opaque userdata |

Bare (untagged) unions default to `.object` because they have no table representation.

### Functions and callbacks

| Zig type | Lua type (encoded) | Lua type (decoded from) | Notes |
|---|---|---|---|
| Zig `fn` | C function | — | Encode only; wrapped automatically via `ZuaFn.new` |
| `ZuaFn.new(fn, cfg)` | C function | — | Statically generated trampoline |
| `ZuaFn.newClosure(fn, initial, cfg)` | C closure (1 upvalue) | — | Capture stored as userdata in upvalue 1 |
| `zua.Function` | function (push) | function | Borrowed handle on decode; call `takeOwnership()` to keep alive |
| `zua.Fn(ins, outs)` | function (push) | function | Typed wrapper; decoded via its `ZUA_META` decode hook |

### Handles

Handles are thin wrappers around Lua values. They participate in the three-tier ownership model: borrowed, stack-owned, or registry-owned.

| Zig type | Lua type (encoded) | Lua type (decoded from) | Ownership on decode | Notes |
|---|---|---|---|---|
| `zua.Table` | table (push existing) | table | borrowed | Points into the current stack frame |
| `zua.TableView(T)` | table (synced on encode) | table | borrowed | Decoded into a heap-backed typed mirror |
| `zua.Function` | function (push existing) | function | borrowed | Raw Lua function handle |
| `zua.Fn(ins, outs)` | function (push existing) | function | borrowed | Typed wrapper over `Function` |
| `zua.Userdata` | userdata (push existing) | userdata | borrowed | Raw untyped full userdata handle |
| `zua.Object(T)` | userdata (push existing) | userdata | borrowed | Typed handle over `zua.Userdata`; `.get()` returns `*T`; used to pass `.object`-strategy values between callbacks |

### VarArgs and Primitive

| Zig type | Usage | Decoded from |
|---|---|---|
| `zua.VarArgs` | Last callback parameter only | All remaining Lua stack slots as `[]Primitive` |
| `zua.Primitive` | Custom decode hooks, VarArgs inspection | Any Lua value via `buildPrimitive` or after `VarArgs` collection |

`Primitive` variants:

| Variant | Lua type |
|---|---|
| `.nil` | nil or absent |
| `.boolean` | boolean |
| `.integer` | integer |
| `.float` | float |
| `.string` | string |
| `.table` | table (borrowed) |
| `.function` | function (borrowed) |
| `.light_userdata` | light userdata |
| `.userdata` | full userdata (borrowed) |

`zua.decodeValue(ctx, prim, T)` converts any `Primitive` into a typed Zig value using the same dispatch as the standard decoder, including optional handling for `.nil`.



## Primitive mapping

### Integers

Lua integers are 64-bit signed. All Zig integers up to `i64` can be round-tripped without loss. Unsigned integers larger than `u63` may be represented as Lua floats, which can lose precision. For values outside that range, use `.object` strategy to store them as opaque userdata.

### Booleans

Zig `bool` values map directly to Lua booleans.

### Strings

`[]const u8` and `[:0]const u8` are mapped directly to Lua strings. When converting strings back and forth during a callback, the returned values should be allocated from the `Context` allocator.

### Zig functions

Zig function values can be pushed to Lua and returned from callbacks, but they cannot be decoded from Lua as arbitrary input values. Lua takes ownership of the function handle for the callable. Use `Function` or typed `Fn` wrappers when you need to accept callbacks from Lua.

## Ownership and lifetimes

### Handle ownership modes

- Borrowed: a handle points to a Lua stack slot owned by the current call frame. It is temporary and must not be retained beyond the callback or while the stack slot can be popped.
- Stack-owned: a handle owns a Lua value on the current stack. It remains valid until `release()` removes it.
- Registry-owned: a handle owns a Lua registry reference. It survives after the current callback and must be released explicitly.

### Lua-owned values

Lua-owned values are GC-managed by Lua. Examples:

- tables
- functions
- full userdata for `.object` strategy values
- Lua strings and other native Lua objects

Lua-owned values can be referenced by handles, but their lifetime is controlled by Lua unless you anchor them with a registry-owned handle.

### Zig-owned values

Zig-owned values are raw Zig memory not managed by Lua. Examples:

- local `T` values on the Zig stack
- `*T` pointers into Zig memory
- allocations from `Context.allocator()` or the state allocator

These values must not be exposed to Lua directly unless wrapped explicitly. `.ptr` strategy values become light userdata, which is a raw pointer only; Lua does not own the pointee. `.object` strategy values must be represented by Lua userdata so Lua can own and GC-manage the allocation.

When an `.object` strategy value contains Zig-owned sub-resources, those sub-resources must be freed in the type's `__gc` metamethod. `__gc` is just another bound method, so it can receive `*Context` and use that context to deallocate or release any nested Zig-owned resources while Lua GC finalizes the userdata.

### Temporal values

Temporal values are valid only for a short-lived scope:

- borrowed handles are valid only while the current Lua stack frame is active
- `Context` allocator allocations live only during the current callback
- values pushed to the Lua stack are valid only until the stack is unwound or the slot is removed

If you need persistence, use a registry-owned handle or move the data into longer-lived Zig memory.

### Longer-lived values

- **Longer-lived**: registry-owned handles, Lua registry references, and GC-managed Lua objects reachable from Lua.
- **Short-lived**: borrowed handles, stack-owned handles until `release()`, and temporary `Context` allocations.

## Table strategy rules

- A table-strategy struct is represented as a Lua table, so its fields are owned by Lua once encoded.
- You cannot receive a raw `*T` as a field in a table-strategy struct because the table owns the representation, not the raw pointer. If you need to mutate table-backed data, use a `Table` handler instead of `*T`.
- You cannot embed `.object` strategy values directly in a table-strategy struct, either as `T` or `*T`. Use a `zua.Userdata` handle (raw) or expose the value through its own `.object` strategy type for nested object references.
- A table-strategy struct cannot contain a field of `.ptr` strategy by value, because `.ptr` values have no direct table representation.
- `ZuaFn` values can be encoded into Lua, but they are not generally decodable from table fields. They are only safe as return values or when the field is never decoded back into Zig.

## Composite values

- Composite values are allowed, but each field must obey its strategy.
- `.object` values are Lua-owned and must be referenced through handles.
- `.ptr` values are raw pointers and do not extend lifetime. Use them only when the referenced pointee is guaranteed to outlive the Lua value.
- `zua.Userdata` is the raw untyped handle for full userdata. `zua.Object(T)` is a typed handle wrapper over `zua.Userdata` that exposes `.get() *T` and participates in the ownership model. The `.object` strategy itself is declared on the target struct with `pub const ZUA_META = zua.Meta.Object(T, methods)`. Use `zua.Object(T)` as a parameter or field type when you need to receive or store a reference to an `.object`-strategy value without holding the allocation directly.
- If a function returns an object, return it via its `.object` strategy type directly; do not return raw `*T` outside a `.ptr`-strategy context.



