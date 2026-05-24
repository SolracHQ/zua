-- stubs.lua: generates editor-completion stubs for app-config.
-- Run with: app-config stubs.lua
local stubs = docs()
local file = io.open("app-config.d.lua", "w")
file:write(stubs)
file:close()
print("stubs written to app-config.d.lua (" .. #stubs .. " bytes)")
