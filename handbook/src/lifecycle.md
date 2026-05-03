# Lifecycle and __gc

`.object` strategy values are allocated as Lua userdata and their lifetime is managed by the Lua garbage collector. When Lua collects an object, it calls the `__gc` metamethod if one is declared. This is where you free any resources the object owns.

## When __gc fires

`__gc` fires when the Lua GC determines the object is unreachable. This is not deterministic; it happens at some point after the last Lua reference to the object is dropped. You can trigger a collection cycle with `collectgarbage("collect")` in Lua, but in normal code you just declare `__gc` and trust that it will run.

```zig
const TextEntry = struct {
    pub const ZUA_META = zua.Meta.Object(TextEntry, .{
        .label = getLabel,
        .__gc  = cleanup,
    }, .{});

    label: []const u8,

    pub fn getLabel(self: *TextEntry) []const u8 {
        return self.label;
    }

    pub fn cleanup(ctx: *zua.Context, self: *TextEntry) void {
        ctx.heap().free(self.label);
    }
};

fn makeEntry(ctx: *zua.Context, label: []const u8) !TextEntry {
    const owned = ctx.heap().dupe(u8, label)
        catch return ctx.fail("out of memory");
    return TextEntry{ .label = owned };
}
```

`cleanup` receives `*zua.Context` like any other zua callback, so it has access to `ctx.heap()` for freeing persistent memory. The `label` slice was duplicated from Lua string memory into the state allocator when the object was created, so it needs to be freed explicitly.

## What __gc does not cover

`__gc` is only called for the **userdata allocation itself**, meaning the struct fields that live inline inside the userdata block. Fields of type `i32`, `f64`, `bool`, and similar scalar types live inline and are collected automatically with the userdata; you do not need to do anything for them.

Fields that point to external memory, `[]const u8`, `*T`, or any other pointer, point to memory outside the userdata block that Lua does not know about. Those must be freed in `__gc`.

Fields that hold Lua handles, `zua.Function`, `zua.Table`, `zua.Object(T)`, anchor Lua values in the registry. Those must be released in `__gc` to avoid leaking Lua references. The [Object handles](./object-handles.md) chapter covers this in detail.

> **Warning:** `.object` values are owned by Lua's garbage collector. If you need to create an additional reference to the same object inside a method, use `.owned()` on the handle instead of copying the typed struct value by assignment. A shallow copy duplicates the payload pointers and can lead to double-free bugs when Lua collects both objects.

## Object fields and the state allocator

When a function creates an `.object` value, zua allocates the userdata in Lua's GC memory and places the Zig struct directly in that allocation. This means:

- Scalar fields like `i32` and `f64` live inside the userdata, no cleanup needed.
- Pointer fields like `[]const u8` point outside the userdata, must be freed in `__gc`.
- Handle fields like `zua.Function` anchor registry references, must be released in `__gc`.

```zig
const Connection = struct {
    pub const ZUA_META = zua.Meta.Object(Connection, .{
        .send  = send,
        .close = close,
        .__gc  = cleanup,
    }, .{});

    // lives inline in userdata, no cleanup
    port: u16,

    // points to external memory, must free in __gc
    host: []const u8,

    // anchors a registry reference, must release in __gc
    on_data: ?zua.Function,

    pub fn send(ctx: *zua.Context, self: *Connection, msg: []const u8) !void {
        _ = ctx; _ = self; _ = msg;
    }

    pub fn close(self: *Connection) void {
        _ = self;
    }

    pub fn cleanup(ctx: *zua.Context, self: *Connection) void {
        ctx.heap().free(self.host);
        if (self.on_data) |cb| cb.release();
    }
};
```

## __gc and the capture strategy

Closures created with `Native.closure` use the `.capture` strategy, which also supports `__gc`. If the captured struct owns heap memory or Lua handles, declare `__gc` in `Meta.Capture` the same way:

```zig
const BufState = struct {
    pub const ZUA_META = zua.Meta.Capture(@This(), .{
        .__gc = cleanup,
    }, .{});
    data:      []u8,
    allocator: std.mem.Allocator,

    fn cleanup(self: *BufState) void {
        self.allocator.free(self.data);
    }
};
```

Lua calls `__gc` when the closure is collected, so the buffer is always freed regardless of how the closure goes out of scope.
