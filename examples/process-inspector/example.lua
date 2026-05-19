-- List processes
local procs = inspector.scan()
print(#procs .. " processes found")

-- Filter by name
local game = inspector.scan({ name = "gameengine" })
local p = game[1]
print("pid:", p.pid, "name:", p.name)

-- Get writable regions
local regions = p:regions("rw-p")
print(#regions .. " writable regions")

-- Scan for i32 > 100
local entries = regions[1]:scan("i32", { gt = 100 })
print(#entries .. " matching entries")
if #entries > 0 then
    local e = entries[1]
    print("address:", string.format("0x%x", e.address))
    print("value:", e:get())
    -- Modify and verify
    e:set(9999)
    print("after set:", e:get())
end

-- Create a direct entry
local direct = inspector.entry({ pid = 1, address = 0x01010000, data_type = "i32" })
print("direct value:", direct:get())
direct:set(42)
print("after set:", direct:get())
