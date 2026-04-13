# Context and arena

Functions that only take arguments and return values do not need anything from the runtime. But most real functions need to allocate memory, format a string, or access state that is not in the arguments. That is what `*zua.Context` is for.

## Adding context to a function

Declare `*zua.Context` as the first parameter. zua recognizes it at compile time and skips it when matching Lua arguments, so from Lua's perspective nothing changes.

```zig
fn greet(ctx: *zua.Context, name: []const u8) []const u8 {
    return std.fmt.allocPrint(ctx.allocator(), "hello, {s}", .{name})
        catch unreachable;
}

globals.set(&ctx, "greet", zua.ZuaFn.new(greet, .{
    .parse_err_fmt = "greet expects (string): {s}",
}));
```

```lua
print(greet("world"))  -- hello, world
```

## The call arena

`ctx.allocator()` returns an arena allocator that lives for the duration of the current call. You can allocate strings, slices, and any temporary value from it without worrying about freeing them individually. zua frees the entire arena automatically after the trampoline has pushed your return value into Lua.

> [!NOTE]
> An arena allocator hands out memory in one direction and frees everything at once. It is very fast and needs no per-allocation bookkeeping. The trade-off is that you cannot free individual items, only the whole arena. Since zua's call arena is freed automatically, individual frees would not make sense anyway.

The string returned by `greet` above is allocated from the arena. zua copies it into Lua's own memory before the arena is freed, so the Lua side always holds a valid string regardless of what happens to the arena.

> [!WARNING]
> Do not hold a pointer into arena memory after the call returns. The memory is gone. If you need a value to outlive the call, for example a string stored in a struct field, allocate it with `ctx.state.allocator` and manage the lifetime yourself.

## ctx.allocator vs ctx.state.allocator

There are two allocators available inside a zua callback:

- `ctx.allocator()` is the call arena. Fast, automatic cleanup, valid only for the duration of the current call.
- `ctx.state.allocator` is the persistent allocator. Survives across calls, must be freed manually, typically in a `__gc` handler.

Use `ctx.allocator()` for anything that is only needed to produce the return value: formatted strings, temporary buffers, intermediate slices. Use `ctx.state.allocator` for anything that needs to outlive the call: object fields, stored callbacks, owned resources.

```zig
const Entry = struct {
    pub const ZUA_META = zua.Meta.Object(Entry, .{
        .label = getLabel,
        .__gc = cleanup,
    });

    // allocated from ctx.state.allocator, survives across calls
    label: []const u8,

    pub fn getLabel(self: *Entry) []const u8 {
        return self.label;
    }

    pub fn cleanup(ctx: *zua.Context, self: *Entry) void {
        ctx.state.allocator.free(self.label);
    }
};

fn makeEntry(ctx: *zua.Context, label: []const u8) !Entry {
    const owned = ctx.state.allocator.dupe(u8, label)
        catch return ctx.fail("out of memory");
    return Entry{ .label = owned };
}
```

`label` starts as a slice pointing into Lua-owned string memory. `dupe` copies it into persistent memory so the `Entry` object can hold it safely after the call returns.

## Context reuse

You create one `Context` and pass it to every call. The arena inside it is reset at the start of each `execute` or `eval`, not when you construct the context. This means the same `ctx` variable works for the whole program lifetime without any manual reset.

```zig
var ctx = zua.Context.init(z);
defer ctx.deinit();

// Both calls share the same ctx; each resets the arena internally.
try executor.execute(&ctx, .{ .code = .{ .string = "greet('alice')" } });
try executor.execute(&ctx, .{ .code = .{ .string = "greet('bob')" } });
```
