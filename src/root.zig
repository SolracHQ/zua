const std = @import("std");

// Low-level Lua API
pub const lua = @import("lua/lua.zig");

// low level isocline bindings
pub const isocline = @import("isocline/isocline.zig");

// State holders
pub const Context = @import("zua/state/context.zig");
pub const State = @import("zua/state/state.zig");

// Handlers
pub const Handlers = @import("zua/handlers/handlers.zig");
pub const Userdata = @import("zua/handlers/userdata.zig");
pub const Table = @import("zua/handlers/table.zig");
pub const Function = @import("zua/handlers/function.zig");

// Typed wrappers
pub const Fn = @import("zua/typed/fn.zig").Fn;
pub const Object = @import("zua/typed/object.zig").Object;
pub const TableView = @import("zua/typed/view.zig").TableView;

// Functions
pub const Native = @import("zua/functions/native.zig");

// Luz-Zig mapping layer
pub const Mapper = @import("zua/mapper/mapper.zig");
pub const Encoder = Mapper.Encoder;
pub const Decoder = Mapper.Decoder;
pub const VarArgs = Mapper.Decoder.VarArgs;

// MetaData System for behavior customization
pub const Meta = @import("zua/meta.zig");

// Final Execution utilities
pub const Executor = @import("zua/exec/executor.zig");
pub const Repl = @import("zua/repl/repl.zig");

// Lua Doc generation utilities
pub const Docs = @import("zua/docs/docs.zig");

test {
    std.testing.refAllDecls(@This());
}
