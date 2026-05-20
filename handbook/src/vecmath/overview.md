# What we are building

We are building a vector library for Lua. Our implementation will be modest but expressive enough to be useful under certain contexts. We will keep the surface small: addition, subtraction, scalar multiplication, equality, length, dot product, cross product, normalization, and linear interpolation. Plus a simple 3x3 transform system with identity, rotation, scale, and apply.

We are not building a full-featured math library. There will be no quaternions, no matrix4x4, no SVD decomposition, no GPU integration. Just vectors and transforms, enough to move things around in 2D and 3D space.

> [!NOTE]
> I chose a vector library because the idea is to build something that looks like a native Lua value. Vectors let us talk about operators, methods, and plain data in a natural way without the examples feeling artificial.

The API we are working toward looks like this:

```lua
local vm = require("vecmath")

local a = vm.vec2(3, 4)
local b = vm.vec2(1, 2)

print(a:length())
print(a:dot(b))
print(a:normalize())

local c = a + b
local d = a - b
local e = a * 2
print(a == vm.vec2(3, 4))

local mid = vm.lerp(a, b, 0.5)

local u = vm.vec3(1, 0, 0)
local v = vm.vec3(0, 1, 0)
print(u:cross(v))
print(u:dot(v))
print(u:length())

local w = u + v

local t = vm.rotate(vm.scale(vm.identity(), 2), math.pi / 4)
local rotated = vm.apply(t, a)
```

| Operation             | What it does               |
| --------------------- | -------------------------- |
| `vm.vec2(x, y)`       | Creates a 2D vector        |
| `vm.vec3(x, y, z)`    | Creates a 3D vector        |
| `a + b`               | Component-wise addition    |
| `a - b`               | Component-wise subtraction |
| `a * n`               | Scalar multiplication      |
| `a == b`              | Equality check             |
| `a:length()`          | Euclidean norm             |
| `a:dot(b)`            | Dot product                |
| `a:cross(b)`          | Cross product (vec3 only)  |
| `a:normalize()`       | Unit vector                |
| `vm.lerp(a, b, t)`    | Linear interpolation       |
| `vm.identity()`       | 3x3 identity matrix        |
| `vm.rotate(t, angle)` | Rotation around Z          |
| `vm.scale(t, factor)` | Uniform scale              |
| `vm.apply(t, v)`      | Transform a vector         |

But before we get there we first need to set up our Zig project to produce the dylib we will run from our Lua interpreter.

> [!NOTE]
> A dylib (dynamic library) is a file with executable code that is not executable by itself. The Lua interpreter can load not only Lua files but also dylibs. When someone writes `require("module_name")`, Lua first looks for a `module_name.lua` file. If it does not find one, it searches the working directory for a `module_name.so` (or `.dll` on Windows) and then searches the paths configured in `package.cpath`. You must place your library either in the working directory or in a directory listed in the path.
