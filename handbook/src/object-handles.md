# Object handles

When you have `.object` strategy values that need to be passed between functions, stored inside other objects, or kept alive beyond the current callback, you need typed handles. `zua.Object(T)` is the handle type for `.object` strategy values. `zua.Handlers` provides utilities to manage ownership recursively when structs contain multiple nested handles.

## zua.Object(T)

`zua.Object(T)` is a typed handle you use as a parameter or field type when you want to receive or store a reference to an `.object` strategy value. It wraps `zua.Userdata` and exposes `.get()` for typed access:

```zig
const Node = struct {
    pub const ZUA_META = zua.Meta.Object(Node, .{
        .value = getValue,
    });
    data: i32,
    pub fn getValue(self: *Node) i32 { return self.data; }
};

const Wrapper = struct {
    pub const ZUA_META = zua.Meta.Object(Wrapper, .{
        .get_node = getNode,
        .__gc     = cleanup,
    });

    node: zua.Object(Node),

    pub fn getNode(self: *Wrapper) i32 {
        return self.node.get().data;
    }

    pub fn cleanup(self: *Wrapper) void {
        self.node.release();
    }
};

fn makeWrapper(_: *zua.Context, node: zua.Object(Node)) Wrapper {
    return Wrapper{ .node = node.takeOwnership() };
}
```

```lua
local n = makeNode(42)
local w = makeWrapper(n)
print(w:get_node())  -- 42
```

`node.get()` returns `*Node`, a direct pointer into the Lua userdata memory. `.takeOwnership()` moves the handle into the registry and releases the old stack-owned reference when applicable, so it is the right choice for newly created userdata values. `.release()` in `__gc` unanchors it so the GC can collect both the `Node` and the `Wrapper` when they go out of scope.

If you need to keep the original handle alive while also creating a registry-owned copy, use `.owned()` instead of `.takeOwnership()`.

`zua.Object(T)` performs compile-time validation: `T` must not be a raw function type, and it must declare `.object` strategy metadata. This catches invalid object-handle declarations before the code compiles.

Key rules:
- `zua.Object(T)` decoded from a function parameter is a **borrowed** handle. Call `.takeOwnership()` if the value must outlive the current callback.
- Use `.owned()` only when you explicitly need to keep the original handle alive as well.
- Do not embed `T` directly in a table-strategy struct. Use `zua.Object(T)` instead.
- Release registry-owned `Object(T)` handles in `__gc` to avoid leaking the Lua reference.

## Handlers.takeOwnership and Handlers.release

When a struct contains multiple nested handles, calling `.takeOwnership()` on each one manually is tedious and easy to get wrong. `Handlers.takeOwnership` walks the value recursively and promotes every handle it finds to registry-owned in one call:

```zig
const Scene = struct {
    background: zua.Object(Texture),
    sprites:    []zua.Object(Sprite),
    on_click:   zua.Function,
};

fn buildScene(bg: zua.Object(Texture), click: zua.Function) Scene {
    var scene = Scene{
        .background = bg,
        .sprites    = &.{},
        .on_click   = click,
    };
    zua.Handlers.takeOwnership(&scene);
    return scene;
}
```

`Handlers.takeOwnership` handles structs, unions, slices, arrays, and optionals recursively. It does not touch non-handle fields. `Handlers.release` does the reverse:

```zig
fn cleanup(self: *Scene) void {
    zua.Handlers.release(Scene, self.*);
}
```

Use `Handlers.release` in `__gc` when the object owns a collection of nested handles that would be tedious to release individually.

## Hiding a pointer on a table

Sometimes you want a Lua-facing table with public fields but a private Zig pointer backing it. Store the pointer as a light userdata key with a name that signals it is private by convention:

```zig
const entry_table = Table.create(z, 0, 3);
entry_table.set(&ctx, "address", "0x7fff1234");
entry_table.setLightUserdata("_ptr", entry_ptr);
entry_table.set(&ctx, "get", zua.ZuaFn.new(entryGet, .{}));
```

Inside the method, retrieve it:

```zig
fn entryGet(ctx: *zua.Context, self: zua.Table) !f64 {
    const entry = self.getLightUserdata("_ptr", Entry)
        catch return ctx.fail("entry pointer missing");
    return entry.read();
}
```

> [!WARNING]
> Light userdata is a raw pointer. The pointed-to value must outlive the Lua state. zua does not track or manage that lifetime. If the Lua state can outlive the pointed-to value, use the `.object` strategy instead, which ties the allocation to Lua's GC.
