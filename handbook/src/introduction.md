# Introduction

If you have ever tried to call Zig code from Lua, you know the pattern. You push arguments onto the Lua stack, call a function, pop results back. Every new function means writing the same push and pop dance again. Change a struct and you chase down every push and pop that touches it. It turns your binding layer into write-only code: you write it once, and from that point on you dread touching it because any change means fixing all the glue code. It is like writing everything twice.

zua generates that glue code at compile time. You write ordinary Zig functions and types, pass them to Lua, and zua handles the stack for you. Change a struct field, the push and pop logic updates with it. Add a new function, the encode and decode paths are generated from the type itself. No registration calls, no runtime reflection, no stack bookkeeping outside of a few specific cases.

## What this book does

The book follows three real projects from an empty Zig file to a complete Lua API. Each project lives in its own part. You pick the project closest to what you are building and follow that part. Concepts are introduced only when the project needs them, explained through the decision that made them necessary. Each chapter adds one piece and you see the whole thing grow.

I wanted something like Crafting Interpreters for zua. I know I am not even near to be mentioned in the same phrase as that book, but I love how it teaches by building. That is what I am trying to do here. Follow its shadow.

## The three projects

### vecmath

A Lua math library distributed as a shared library that Lua loads with `require("vecmath")`. You build Vec2 and Vec3 types with arithmetic operators, a lerp function, transform matrices, and docs generation. This project stays almost entirely in the table strategy, mostly for didactic purposes.

You build a Lua module that Lua loads with `require`. You write Vec2 and Vec3 as plain Zig structs and expose them as Lua tables. You add methods, operator overloads, iteration, and editor stubs so script authors get autocomplete.

### app-config

A Zig application that creates and owns the Lua VM, registers globals, and runs a user script that configures a mock HTTP server. You build an AppConfig decoder, an App builder with chainable methods, route handlers as Lua callbacks, and a stateful middleware closure.

You build a Zig program that owns the Lua VM. Lua scripts configure a mock HTTP server. You decode config tables with optional fields and flexible address formats. You store Lua callbacks as route handlers and middleware. You manage memory with `__gc` and build a stateful middleware chain using closures.

### process-inspector

A Zig application with a built-in REPL that exposes a mock process memory inspection API. You build a process list, memory regions, scan entries, typed memory selectors, and a live interactive shell.

You build a REPL-driven tool that exposes process lists, memory regions, and scan entries as typed Lua objects. You filter results, write back to memory, and get autocompletion in the shell. Lua is the frontend, Zig is the backend.


