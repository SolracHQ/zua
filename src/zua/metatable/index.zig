//! Generates the __index trampoline for a Zua object type.

const std = @import("std");
const lua = @import("../../lua/lua.zig");
const ShapeData = @import("../shape/shape_data.zig");
const Modifier = @import("../shape/modifier.zig");
const Maps = @import("maps.zig");
const Field = @import("field.zig");
const Introspection = @import("introspection.zig");
const Trampoline = @import("trampoline.zig");

/// Builds the `__index` metamethod for type T. Checks introspection, regular methods, then Field/Value fields, then a
/// custom `__index` if declared in the shape.
pub fn objectIndexTrampoline(comptime T: type) lua.CFunction {
    const methods = comptime ShapeData.methodsOf(T);
    const methods_type = comptime @TypeOf(methods);
    const has_custom_index = comptime @hasField(methods_type, "__index");
    const method_map = comptime Maps.methodMap(methods);
    const field_map = comptime Maps.fieldIndexMap(T);

    return struct {
        fn index(L: ?*lua.State) callconv(.c) c_int {
            if (lua.valueType(L.?, 2) == .string) {
                const key = lua.toString(L.?, 2) orelse return 0;

                if (std.mem.eql(u8, key, "__introspection")) {
                    return Introspection.introspectionTable(L, methods, T);
                }

                if (method_map.get(key)) |trampoline| {
                    lua.pushFunction(L.?, trampoline);
                    return 1;
                }

                if (field_map.get(key)) |field_idx| {
                    inline for (@typeInfo(T).@"struct".fields, 0..) |field, fi| {
                        if (fi == field_idx and comptime Modifier.isFieldOrValue(field.type)) {
                            return Field.fieldIndex(L, T, field.name);
                        }
                    }
                }
            }
            if (comptime has_custom_index) {
                const trampoline = comptime Trampoline.selectTrampoline(@field(methods, "__index"), "__index");
                return trampoline.?(L);
            }
            return 0;
        }
    }.index;
}
