const std = @import("std");
pub const Args = @import("lua/args.zig").Args;
pub const Result = @import("lua/result.zig").Result;
pub const Table = @import("lua/table.zig").Table;
pub const Zua = @import("lua/zua.zig").Zua;
pub const lua = @import("lua/lua.zig");

test {
    std.testing.refAllDecls(@This());
}
