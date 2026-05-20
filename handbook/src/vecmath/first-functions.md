# First functions

At this point I can imagine you thinking: "Hey, I can do this with the pure Lua C API, and it is even simpler! What is zua providing aside from boilerplate?" And you are right. Right now we have a glorified and overengineered hello world. But from this point on you will not need to call `push` again. Never. You will not even see the Lua bindings again.

Lets start doing something useful. A vector library needs vectors, so lets create one.

Create a file called `src/vec2.zig`:

```zig
const std = @import("std");
const zua = @import("zua");

pub const Vec2 = struct {
    x: f64,
    y: f64,
};
```

Now in `src/main.zig`, add the import and change the `push` line (the rest stays the same as setup):

```zig
const Vec2 = @import("vec2.zig").Vec2;

export fn luaopen_vecmath(L: *lua.State) c_int {
    // ... threaded io, libState, context init (same as before) ...
    zua.Mapper.Encoder.push(&ctx, Vec2{ .x = 20.0, .y = 30.0 }) catch return 0;
    return 1;
}
```

Build it and run from Lua:

```lua
local vm = require("vecmath")
print(vm.x, vm.y)
```

You will see `20  30` printed.

Maybe if you are not familiar with the Lua C API you will think "Thats all? You just push a struct into Lua?" But for those more familiar with the C API, notice what we did not do: create a table, push values on the stack, set keys one by one. We just pushed it and it worked. All that hard work was handled by zua at comptime.

But even now, our library is still kind of useless. We only return one fixed vector. Lets improve it by adding a function to create vectors. On zua it is as simple as writing a plain Zig function:

```zig
fn vec2(x: f64, y: f64) Vec2 {
    return .{ .x = x, .y = y };
}
```

Now push the function instead of the fixed vector (again, same setup, only the push line changes):

```zig
zua.Mapper.Encoder.push(&ctx, vec2) catch return 0;
```

Build it and try it from Lua:

```lua
local vm = require("vecmath")

local a = vm.vec2(3, 4)
local b = vm.vec2(1, 2)
local c = vm.vec2(10, 20)

print(a.x, a.y)
print(b.x, b.y)
print(c.x, c.y)
```

That is it. Create a Zig function, return a Zig struct, and use it from Lua. All the encoding and decoding happen automatically. That single `push` call creates at compile time all the optimized paths that call the required Lua API functions to encode the function and its return type and decode the function arguments. The only runtime behavior is calling the Lua API to check types and interact with the stack.

We went from an overengineered hello world to a usable vector builder in less than 10 lines of new code.
