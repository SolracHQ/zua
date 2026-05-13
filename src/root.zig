const std = @import("std");

/// Low-level C binding wrappers. `Bindings.lua` exposes the raw Lua C API,
/// `Bindings.isocline` exposes the isocline line editor C bindings.
/// Most users do not need these directly unless writing custom C interop
/// or embedding Lua in non-standard ways.
pub const Bindings = struct {
    /// Raw Lua C API (`lua_State`, `lua_push*`, etc.).
    pub const lua = @import("lua/lua.zig");
    /// Isocline line editor C bindings.
    pub const isocline = @import("isocline/isocline.zig");
};

// Core state
pub const Context = @import("zua/state/context.zig");
pub const State = @import("zua/state/state.zig");

// Raw Lua value handles (Table, Function, Userdata) and ownership helpers
pub const Handlers = @import("zua/handlers/handlers.zig");

// Encode/decode pipeline
pub const Mapper = @import("zua/mapper/mapper.zig");

// Shapes how Zig types look from the Lua side
pub const Shape = @import("zua/shape/shape.zig");

// REPL, execution, and docs
pub const Repl = @import("zua/repl/repl.zig");
pub const Executor = @import("zua/exec/executor.zig");
pub const Docs = @import("zua/docs/docs.zig");

// Flat re-export for users that already know the API
pub const Prelude = @import("prelude.zig");

test {
    std.testing.refAllDecls(@This());
}
