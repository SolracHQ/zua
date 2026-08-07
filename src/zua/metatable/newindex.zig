//! Generates the __newindex trampoline for a Zua object type.

const std = @import("std");
const lua = @import("../../lua/lua.zig");
const ShapeData = @import("../shape/shape_data.zig");
const Modifier = @import("../shape/modifier.zig");
const Maps = @import("maps.zig");
const Field = @import("field.zig");
const Trampoline = @import("trampoline.zig");

/// Builds the `__newindex` metamethod for type T. Writes to writable Field fields, rejects Value (read-only) fields, and
/// falls back to a custom `__newindex` if declared in the shape.
pub fn objectNewIndexTrampoline(comptime T: type) lua.CFunction {
    const methods = comptime ShapeData.methodsOf(T);
    const methods_type = comptime @TypeOf(methods);
    const has_custom_newindex = comptime @hasField(methods_type, "__newindex");
    const field_map = comptime Maps.fieldIndexMap(T);

    return struct {
        fn newindex(L: ?*lua.State) callconv(.c) c_int {
            if (lua.valueType(L.?, 2) == .string) {
                const key = lua.toString(L.?, 2) orelse return 0;

                if (field_map.get(key)) |field_idx| {
                    inline for (@typeInfo(T).@"struct".fields, 0..) |field, fi| {
                        if (fi == field_idx and comptime Modifier.isFieldOrValue(field.type)) {
                            const state = L orelse unreachable;
                            if (comptime Modifier.isValue(field.type)) {
                                lua.pushString(state, "field '" ++ field.name ++ "' is read-only");
                                return lua.raiseError(state);
                            }
                            return Field.fieldNewIndex(L, T, field.name, Modifier.innerType(field.type));
                        }
                    }
                }
            }
            if (comptime has_custom_newindex) {
                const trampoline = comptime Trampoline.selectTrampoline(@field(methods, "__newindex"), "__newindex");
                return trampoline.?(L);
            }
            return 0;
        }
    }.newindex;
}
