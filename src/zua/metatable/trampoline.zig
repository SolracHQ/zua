//! Converts a Zua method declaration into a `lua.CFunction` trampoline.

const std = @import("std");
const lua = @import("../../lua/lua.zig");
const ShapeData = @import("../shape/shape_data.zig");
const Shape = @import("../shape/api.zig");

/// Returns the CFunction trampoline for a Zua method.
/// Emits a compile error if `method_fn` is not callable.
pub fn selectTrampoline(comptime method_fn: anytype, comptime name: []const u8) lua.CFunction {
    const method_fn_type = @TypeOf(method_fn);

    if (comptime ShapeData.isFunction(method_fn_type)) {
        return method_fn_type.trampoline();
    }

    if (comptime @typeInfo(method_fn_type) == .type and ShapeData.isFunction(method_fn)) {
        return method_fn.trampoline();
    }

    if (comptime @typeInfo(method_fn_type) != .@"fn") {
        @compileError("method `" ++ name ++ "` is not a function");
    }

    return Shape.Fn(method_fn, .{}).trampoline();
}
