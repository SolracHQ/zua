//! Comptime counters for ZUA_SHAPE declarations.

const std = @import("std");
const ShapeData = @import("../shape/shape_data.zig");
const Modifier = @import("../shape/modifier.zig");

/// Returns the number of non-metamethod methods declared for T.
pub fn regularMethodCount(comptime T: type) i32 {
    const methods = comptime ShapeData.methodsOf(T);
    comptime var count: i32 = 0;
    inline for (@typeInfo(@TypeOf(methods)).@"struct".fields) |field| {
        if (!std.mem.startsWith(u8, field.name, "__")) count += 1;
    }
    return count;
}

/// Returns the number of Field/Value-declared fields in T.
pub fn objectFieldCount(comptime T: type) i32 {
    if (comptime @typeInfo(T) != .@"struct") return 0;
    comptime var count: i32 = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime Modifier.isFieldOrValue(field.type)) count += 1;
    }
    return count;
}
