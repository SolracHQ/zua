const std = @import("std");
const zua = @import("zua");

// DataType is a string enum. StrAlias tells zua to encode variant names
// as Lua strings. The Docs generator emits `---@alias DataType` with
// each variant listed. Lua callers pass "i32" or "f32".

pub const DataType = enum {
    i32,
    f32,

    pub const ZUA_SHAPE = zua.Shape.StrAlias(DataType, .{}, .{
        .name = "DataType",
        .description = "i32 or f32 memory data type.",
    });
};
