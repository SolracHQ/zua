//! Field and value markers for diferent shapes.
//!
//! `Shape.Modifier.Field(T, opts)` and `Shape.Modifier.Value(T, opts)` mark
//! struct fields as readable (Value) or readable and writable (Field) from Lua.

const Marker = @import("../marker.zig").Marker;

/// Options for `Shape.Modifier.Field` and `Shape.Modifier.Value`.
pub const FieldOpts = struct {
    description: []const u8 = "",
};

/// Declare a struct field as readable and writable from Lua.
pub fn Field(comptime T: type, comptime opts: FieldOpts) type {
    return struct {
        pub const __ZUA_MARKER = Marker.object_field;
        pub const __ZUA_FIELD_TYPE = T;
        pub const __ZUA_FIELD_OPTS = opts;
        value: T,

        pub fn new(value: T) @This() {
            return .{ .value = value };
        }
    };
}

/// Declare a struct field as read-only from Lua.
pub fn Value(comptime T: type, comptime opts: FieldOpts) type {
    return struct {
        pub const __ZUA_MARKER = Marker.object_value;
        pub const __ZUA_FIELD_TYPE = T;
        pub const __ZUA_FIELD_OPTS = opts;
        value: T,

        pub fn new(value: T) @This() {
            return .{ .value = value };
        }
    };
}

/// Returns the inner type `T` of a `Field` or `Value` wrapper.
pub fn innerType(comptime Wrapper: type) type {
    return Wrapper.__ZUA_FIELD_TYPE;
}

/// Returns the options of a `Field` or `Value` wrapper.
pub fn fieldOpts(comptime Wrapper: type) FieldOpts {
    return Wrapper.__ZUA_FIELD_OPTS;
}

/// Returns `true` if `T` is a `Field` or `Value` wrapper.
pub fn isFieldOrValue(comptime T: type) bool {
    return Marker.any(T, &.{ .object_field, .object_value });
}

/// Returns `true` if `T` is a `Field` wrapper (writable).
pub fn isField(comptime T: type) bool {
    return Marker.markerOf(T).contains(.object_field);
}

/// Returns `true` if `T` is a `Value` wrapper (read-only).
pub fn isValue(comptime T: type) bool {
    return Marker.markerOf(T).contains(.object_value);
}
