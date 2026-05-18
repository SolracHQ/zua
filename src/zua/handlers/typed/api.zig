//! Typed handler wrappers for Lua values bound to a specific Zig type.

pub const Fn = @import("fn.zig").Fn;
pub const Object = @import("object.zig").Object;
pub const Closure = @import("closure.zig").Closure;
pub const TableView = @import("table_view.zig").TableView;
