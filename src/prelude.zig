const std = @import("std");

pub const lua = @import("lua/lua.zig");
pub const isocline = @import("isocline/isocline.zig");

pub const Context = @import("zua/state/context.zig");
pub const State = @import("zua/state/state.zig");

pub const Handlers = @import("zua/handlers/handlers.zig");

pub const Table = Handlers.Any.Table;
pub const Function = Handlers.Any.Function;
pub const Userdata = Handlers.Any.Userdata;

pub const Fn = Handlers.Typed.Fn;
pub const Object = Handlers.Typed.Object;
pub const TableView = Handlers.Typed.TableView;

pub const Mapper = @import("zua/mapper/mapper.zig");
pub const Encoder = Mapper.Encoder;
pub const Decoder = Mapper.Decoder;
pub const VarArgs = Mapper.Decoder.VarArgs;
pub const Primitive = Mapper.Primitive;

pub const Shape = @import("zua/shape/shape.zig");

pub const Executor = @import("zua/exec/executor.zig");
pub const Repl = @import("zua/repl/repl.zig");
pub const Docs = @import("zua/docs/docs.zig");

test {
    std.testing.refAllDecls(@This());
}
