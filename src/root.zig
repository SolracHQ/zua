const std = @import("std");
pub const Result = @import("zua/result.zig").Result;
pub const Table = @import("zua/table.zig").Table;
pub const Function = @import("zua/function.zig").Function;
pub const Zua = @import("zua/zua.zig").Zua;
pub const ZuaFn = @import("zua/zua_fn.zig");
pub const lua = @import("lua/lua.zig");
pub const translation = @import("zua/translation.zig");
pub const meta = @import("zua/meta.zig");

test {
    std.testing.refAllDecls(@This());
}
