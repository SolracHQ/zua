# Introduction

zua lets you write Zig and call it from Lua.

The mental model is simple: you are not embedding Lua into your program. You are exposing pieces of your Zig program to Lua scripts. The Lua state is just the runtime that calls your code. zua handles the boundary so you can focus on the Zig side.

The three things zua takes care of:

- decoding Lua arguments into typed Zig values before your function sees them
- converting your Zig return values back into Lua values
- making sure `lua_error` only fires after your function has fully returned, so `defer` is safe

Everything else is still Zig. Allocation, logic, error handling, data structures, all of it stays in Zig and works the way you expect.

Start with `functions.md` to see how callbacks are defined and registered.