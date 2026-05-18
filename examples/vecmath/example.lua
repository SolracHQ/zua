local vm = require("vecmath")

-- Vec2 is a normal Lua table with x and y fields.
-- You can read and write the fields directly.
local a = vm.vec2(3, 4)
local b = vm.vec2(1, 2)

-- Utility functions accessible via the colon syntax.
print("vec2(3, 4):length() =", a:length())
print("vec2(3, 4):dot(vec2(1, 2)) =", a:dot(b))
print("vec2(3, 4):normalize() =", a:normalize())

-- Operators work on vec2 values. Each returns a new table.
local c = a + b
print("a + b =", c.x, c.y)

local d = a - b
print("a - b =", d.x, d.y)

local e = a * 2
print("a * 2 =", e.x, e.y)

print("a == vm.vec2(3, 4) =", a == vm.vec2(3, 4))

-- Module-level helpers like lerp are also available.
local mid = vm.lerp(a, b, 0.5)
print("lerp(a, b, 0.5) =", mid.x, mid.y)

-- Vec3 has three fields and adds a cross product.
local u = vm.vec3(1, 0, 0)
local v = vm.vec3(0, 1, 0)
print("vec3(1,0,0):cross(vec3(0,1,0)) =", u:cross(v))
print("vec3(1,0,0):dot(vec3(0,1,0)) =", u:dot(v))
print("vec3(1,0,0):length() =", u:length())

local w = u + v
print("u + v =", w.x, w.y, w.z)

-- Transform is a 3x3 nested array {{a,b,c},{d,e,f},{g,h,i}}.
-- Functions like rotate, scale, and apply operate on it.
local t = vm.rotate(vm.scale(vm.identity(), 2), math.pi / 4)
local rotated = vm.apply(t, a)
print("apply(rotate(scale(identity(),2),pi/4), vec2(3,4)) =", rotated.x, rotated.y)
