//! Comptime-built lookup maps for the runtime trampoline dispatch.

const std = @import("std");
const lua = @import("../../lua/lua.zig");
const Modifier = @import("../shape/modifier.zig");
const Trampoline = @import("trampoline.zig");

/// Maps regular method names to their CFunction trampolines.
/// Metamethods (names starting with `__`) are excluded.
pub fn methodMap(comptime methods: anytype) std.StaticStringMap(lua.CFunction) {
    const fields = @typeInfo(@TypeOf(methods)).@"struct".fields;
    var count: usize = 0;
    for (fields) |f| {
        if (!std.mem.startsWith(u8, f.name, "__")) count += 1;
    }
    var entries: [count]struct { []const u8, lua.CFunction } = undefined;
    var i: usize = 0;
    for (fields) |f| {
        if (!std.mem.startsWith(u8, f.name, "__")) {
            entries[i] = .{ f.name, Trampoline.selectTrampoline(@field(methods, f.name), f.name) };
            i += 1;
        }
    }
    return std.StaticStringMap(lua.CFunction).initComptime(entries);
}

/// Maps Field/Value field names to their index in T's struct fields.
pub fn fieldIndexMap(comptime T: type) std.StaticStringMap(usize) {
    const fields = @typeInfo(T).@"struct".fields;
    var count: usize = 0;
    for (fields) |f| {
        if (Modifier.isFieldOrValue(f.type)) count += 1;
    }
    var entries: [count]struct { []const u8, usize } = undefined;
    var i: usize = 0;
    for (fields, 0..) |f, idx| {
        if (Modifier.isFieldOrValue(f.type)) {
            entries[i] = .{ f.name, idx };
            i += 1;
        }
    }
    return std.StaticStringMap(usize).initComptime(entries);
}
