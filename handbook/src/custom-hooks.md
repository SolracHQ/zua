# Custom Translation Hooks

Sometimes you need fine-grained control over how Zig types are encoded to Lua or decoded from Lua. zua provides two customization mechanisms: encode hooks and decode hooks.

## Encode hooks: Transform before pushing

An encode hook transforms a Zig value into a different type before pushing it to the Lua stack. This is useful for converting enums to human-readable strings instead of numbers, or serializing complex types into simpler representations.

Define an encode hook by declaring `ZUA_ENCODE_CUSTOM_HOOK` as a function on your type:

```zig
const Status = enum(u8) {
    idle = 0,
    running = 1,
    stopped = 2,

    pub const ZUA_ENCODE_CUSTOM_HOOK = encodeStatusAsString;

    fn encodeStatusAsString(status: Status) []const u8 {
        return switch (status) {
            .idle => "idle",
            .running => "running",
            .stopped => "stopped",
        };
    }
};
```

When you return a `Status` from a Zig callback:

```zig
fn getStatus(_: *zua.Zua) zua.Result(Status) {
    return zua.Result(Status).ok(.running);
}
```

The Lua code receives a string, not a number:

```lua
local status = get_status()
print(status)  -- prints: "running"
print(type(status))  -- prints: "string"
```

The hook must return a different type than the input. This prevents infinite recursion. You cannot use an encode hook to transform `Status` into another `Status`.

## Decode hooks: Accept multiple input types

A decode hook allows a Zig type to accept Lua values of different types and convert them appropriately. This is useful for type-flexible APIs that work with multiple representations: accepting addresses as numbers, hex strings, or existing handles.

Define a decode hook by declaring `ZUA_DECODE_CUSTOM_HOOK` as a function that receives the `Zua` instance, stack index, and value type:

```zig
pub const Address = struct {
    value: u64,

    pub const ZUA_DECODE_CUSTOM_HOOK = decodeAddressHook;

    fn decodeAddressHook(z: *zua.Zua, index: zua.lua.StackIndex, kind: zua.lua.Type) !Address {
        const value: u64 = switch (kind) {
            .number => num: {
                const int_val = zua.lua.toInteger(z.state, index) orelse return error.InvalidType;
                break :num @intCast(int_val);
            },
            .userdata => ud: {
                if (zua.lua.toUserdata(z.state, index)) |ptr| {
                    const addr_ptr: *Address = @ptrCast(@alignCast(ptr));
                    break :ud addr_ptr.value;
                }
                return error.InvalidType;
            },
            else => return error.InvalidType,
        };
        return Address{ .value = value };
    }
};
```

Now this Zig function accepts `Address` from multiple Lua input types:

```zig
fn testAddress(_: *zua.Zua, addr: Address) zua.Result(u64) {
    return zua.Result(u64).ok(addr.value);
}
```

The Lua code can call it with either a number or a userdata handle:

```lua
-- From a number
print(testAddress(0xdeadbeef))  -- works

-- From a userdata handle (created earlier)
print(testAddress(myAddressHandle))  -- also works
```

The hook receives the `lua.Type` enum value, allowing you to dispatch on:

- `.number` for Lua numbers (integers and floats)
- `.string` for Lua strings
- `.userdata` for heavy userdata (created with `lua_newuserdata`)
- `.light_userdata` for light userdata pointers
- `.table` for Lua tables
- `.function` for Lua functions or other types

Return `error.InvalidType` if a type combination does not make sense.

## Combining hooks with enums

Enums support both hooks naturally. Without hooks, enums are encoded as integers and must be decoded from integers:

```zig
const Color = enum(u8) {
    red = 0,
    green = 1,
    blue = 2,
};
```

With an encode hook, the same enum pushes as a string but still decodes from integers:

```zig
const Status = enum(u8) {
    idle = 0,
    running = 1,
    stopped = 2,

    pub const ZUA_ENCODE_CUSTOM_HOOK = encodeStatusAsString;
    // ... encode hook ...
};
```

This asymmetry is intentional. Lua code calls your functions to get human-readable representations, but your Zig code can be flexible about accepting various inputs from the user.
