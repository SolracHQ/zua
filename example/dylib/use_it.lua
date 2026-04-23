local vecmath = require("vecmath")

local a = vecmath.vec2(3, 4)
local b = vecmath.vec2(1, 2)

print(a:length())        -- 5.0
print(a:dot(b))          -- 11.0

local c = a:add(b)
print(c.x, c.y)          -- 4.0  6.0

local n = a:normalize()
print(n.x, n.y)          -- 0.6  0.8

local mid = vecmath.lerp(a, b, 0.5)
print(mid.x, mid.y)      -- 2.0  3.0