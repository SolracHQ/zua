//! Unbound Lua value handles. `Any.Table` works with any Lua table, `Any.Function` with any
//! Lua function, `Any.Userdata` with any Lua userdata. They provide typed operations (get/set/call)
//! but are not bound to a specific Zig type like the wrappers in `Typed`.
//!
//! > NOTE: even though `get` and `set` accept any type at the call site, the decode and encode
//! > paths are comptime-generated from the requested type. There is no runtime dispatch, no boxing,
//! > and no overhead compared to calling the encoder or decoder directly.

pub const Table = @import("table.zig");
pub const Function = @import("function.zig");
pub const Userdata = @import("userdata.zig");
pub const UpValue = @import("upvalue.zig");
