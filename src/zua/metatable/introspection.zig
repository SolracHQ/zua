const std = @import("std");
const lua = @import("../../lua/lua.zig");
const Modifier = @import("../shape/modifier.zig");

/// Builds a table of member names for type `T`.
///
/// The table uses sequential integer keys (1..n) with method and field names as string values. Methods appear first
/// (excluding `__`-prefixed metamethods), followed by struct fields declared as `Shape.Modifier.Field` or
/// `Shape.Modifier.Value`.
///
/// This is triggered when Lua code indexes a userdata with the special `__introspection` key. The REPL completion system
/// (`zua.repl.completion`) calls this to discover available members without accessing the metatable directly.
pub fn introspectionTable(L: ?*lua.State, comptime methods: anytype, comptime T: type) c_int {
    const methods_type = @TypeOf(methods);
    lua.createTable(L.?, 0, 0);
    var idx: i32 = 1;
    inline for (@typeInfo(methods_type).@"struct".fields) |field| {
        if (!std.mem.startsWith(u8, field.name, "__")) {
            lua.pushString(L.?, field.name);
            lua.setIndex(L.?, -2, idx);
            idx += 1;
        }
    }
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime Modifier.isFieldOrValue(field.type)) {
            lua.pushString(L.?, field.name);
            lua.setIndex(L.?, -2, idx);
            idx += 1;
        }
    }
    return 1;
}
