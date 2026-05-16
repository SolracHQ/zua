//! Comptime type introspection helpers used by the trampolines and docs
//! generator. Not part of the public API, used internally to unwrap
//! error unions, detect tuples, count and index type lists, and check
//! for closure capture pointers.

const std = @import("std");
const ShapeData = @import("shape/shape_data.zig");

/// Returns whether `T` is a pointer to a closure strategy type.
pub fn isCapturePointer(comptime T: type) bool {
    if (@typeInfo(T) != .pointer) return false;
    const ptr = @typeInfo(T).pointer;
    if (ptr.size != .one) return false;
    const Child = ptr.child;
    const s = ShapeData.strategyOf(Child);
    return s == .closure;
}

/// Returns whether `T` is a struct tuple type (`is_tuple`).
pub fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
}

/// Returns whether `T` is an error union type.
pub fn isErrorUnion(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

/// Returns the payload type of an error union, or `T` unchanged otherwise.
pub fn unwrapErrorUnion(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        else => T,
    };
}

/// Returns the number of elements in a type spec.
///
/// `void` → 0, a single non-tuple type → 1, a tuple type → field count.
/// When `spec` is not a type but a slice/array, returns the length.
pub fn typeListCount(comptime spec: anytype) usize {
    const SpecType = @TypeOf(spec);
    if (SpecType == type) {
        const info = @typeInfo(spec);
        if (info == .void) return 0;
        if (info == .@"struct" and info.@"struct".is_tuple) return info.@"struct".fields.len;
        return 1;
    }
    return spec.len;
}

/// Returns the type at `index` within a type spec.
///
/// Index 0 on a non-tuple type returns the type itself.
/// For tuple types, returns the field type at the given index.
/// When `spec` is not a type but a slice/array, returns `spec[index]`.
pub fn typeListAt(comptime spec: anytype, comptime index: usize) type {
    const SpecType = @TypeOf(spec);
    if (SpecType == type) {
        const info = @typeInfo(spec);
        if (info == .@"struct" and info.@"struct".is_tuple) return info.@"struct".fields[index].type;
        if (index == 0) return spec;
        @compileError("typeListAt index out of bounds for non-tuple type " ++ @typeName(spec));
    }
    return spec[index];
}

test {
    std.testing.refAllDecls(@This());
}
