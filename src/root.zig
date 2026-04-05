const std = @import("std");
pub const Result = @import("lua/result.zig").Result;
pub const Table = @import("lua/table.zig").Table;
pub const Zua = @import("lua/zua.zig").Zua;
pub const ZuaFn = @import("lua/zua_fn.zig");
pub const lua = @import("lua/lua.zig");
pub const translation = @import("lua/translation.zig");

test {
    std.testing.refAllDecls(@This());
}
