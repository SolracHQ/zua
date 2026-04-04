# Host State

Callbacks often need access to application state that Lua should not see or modify directly. The standard pattern is light userdata stored in the registry.

## Storing state

```zig
var app = AppState{ .next_id = 1000 };

const registry = z.registry();
defer registry.pop();
registry.setLightUserdata("app", &app);
```

## Reading state inside a callback

```zig
fn nextId(z: *Zua) Result(i32) {
    const registry = z.registry();
    defer registry.pop();

    const app = registry.getLightUserdata("app", AppState) catch return Result(i32).errStatic("app state missing");
    app.next_id += 1;
    return Result(i32).ok(app.next_id - 1);
}
```

## Hidden pointer on a Lua-facing table

You can also attach a hidden pointer directly to a table you return to Lua. This is useful when a Lua-facing object wraps a specific Zig value rather than shared global state.

```zig
const entry_table = z.createTable(0, 3);
entry_table.set("address", "0x7fff1234");
entry_table.setLightUserdata("_ptr", entry_ptr);
entry_table.setFn("get", ZuaFn.from(entryGet, "entry:get takes no arguments"));
```

Inside the method:

```zig
fn entryGet(z: *Zua, self: Table) Result(f64) {
    const entry = self.getLightUserdata("_ptr", Entry) catch return Result(f64).errStatic("entry pointer missing");
    _ = z;
    return Result(f64).ok(entry.read());
}
```

The underscore prefix on `_ptr` is a convention to signal to Lua script authors that the field is private. Lua can still read it if it tries, but it is not part of the public API.

## Lifetime

Light userdata is a raw pointer. The pointed-to value must outlive the `Zua` instance. zua does not track or manage that lifetime for you.