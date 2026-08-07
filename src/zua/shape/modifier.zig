//! Field and value markers for diferent shapes.
//!
//! `Shape.Modifier.Field(T, opts)` and `Shape.Modifier.Value(T, opts)` mark struct fields as readable (Value) or readable
//! and writable (Field) from Lua.

const Marker = @import("../marker.zig").Marker;
const Trampoline = @import("trampoline.zig");
const Context = @import("../context.zig");

/// Options for `Shape.Modifier.Field` and `Shape.Modifier.Value`.
pub const FieldOpts = struct {
    description: []const u8 = "",
};

/// Declare a struct field as readable and writable from Lua on an Object shape.
pub fn Field(comptime T: type, comptime opts: FieldOpts) type {
    return struct {
        pub const __ZUA_MARKER = Marker.object_field;
        const FieldType = T;
        const FieldOpts = opts;
        value: T,

        pub fn new(value: T) @This() {
            return .{ .value = value };
        }
    };
}

/// Declare a struct field as read-only from Lua on an Object shape.
pub fn Value(comptime T: type, comptime opts: FieldOpts) type {
    return struct {
        pub const __ZUA_MARKER = Marker.object_value;
        const FieldType = T;
        const FieldOpts = opts;
        value: T,

        pub fn new(value: T) @This() {
            return .{ .value = value };
        }
    };
}

/// Returns the inner type `T` of a `Field` or `Value` wrapper.
pub fn innerType(comptime Wrapper: type) type {
    return Wrapper.FieldType;
}

/// Returns the options of a `Field` or `Value` wrapper.
pub fn fieldOpts(comptime Wrapper: type) FieldOpts {
    return Wrapper.FieldOpts;
}

/// Returns `true` if `T` is a `Field` or `Value` wrapper.
pub fn isFieldOrValue(comptime T: type) bool {
    return Marker.any(T, &.{ .object_field, .object_value });
}

/// Wraps a field type so the encode/decode pipeline skips it. The field exists in Zig but is invisible to table
/// serialization.
pub fn Ignore(comptime T: type) type {
    return struct {
        pub const __ZUA_MARKER = Marker.ignore;
        value: T,

        pub fn new(value: T) @This() {
            return .{ .value = value };
        }
    };
}

/// Returns `true` if `T` carries the `ignore` marker.
pub fn isIgnored(comptime T: type) bool {
    return Marker.markerOf(T).contains(.ignore);
}

/// Returns `true` if `T` is a `Field` wrapper (writable).
pub fn isField(comptime T: type) bool {
    return Marker.markerOf(T).contains(.object_field);
}

/// Returns `true` if `T` is a `Value` wrapper (read-only).
pub fn isValue(comptime T: type) bool {
    return Marker.markerOf(T).contains(.object_value);
}

/// Mark a function as a method so docs skip the self parameter.
/// ```zig
/// const methods = .{
///     .listen = Modifier.Method(listen, .{ .description = "Set the address." }),
/// };
/// ```
pub fn Method(comptime func: anytype, comptime opts: Trampoline.FnOptions) type {
    const FunctionType = @TypeOf(func);
    const fn_info = comptime @typeInfo(FunctionType).@"fn";
    const has_context = comptime fn_info.params.len > 0 and fn_info.params[0].type == *Context;
    return struct {
        pub const __ZUA_MARKER = Marker.method_config;
        pub const Fn = func;
        pub const FnOptions = opts;
        pub const HasContext = has_context;
    };
}
