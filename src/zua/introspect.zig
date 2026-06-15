//! Comptime type introspection helpers used by the trampolines and docs generator. Not part of the public API, used
//! internally to unwrap error unions, detect tuples, count and index type lists, and check for closure capture pointers.

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
/// `void` → 0, a single non-tuple type → 1, a tuple type → field count. When `spec` is not a type but a slice/array,
/// returns the length.
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
/// Index 0 on a non-tuple type returns the type itself. For tuple types, returns the field type at the given index. When
/// `spec` is not a type but a slice/array, returns `spec[index]`.
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

/// Returns `true` if `T` is a struct, union, enum, or opaque type.
pub fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

/// Returns the container type (struct, union, enum, opaque) for a comptime value, or `null` if the value is not a
/// container. When the value itself is a type, returns the type if it is a container. When the value is a container
/// instance, returns its type.
pub fn getContainer(comptime v: anytype) ?type {
    const T = @TypeOf(v);
    if (T == type) {
        return switch (@typeInfo(v)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => v,
            else => null,
        };
    }
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => T,
        else => null,
    };
}

/// Parameters for `actualArgCount` and `actualArgs`.
pub const ArgConfig = struct {
    has_context: bool = false,
    is_method: bool = false,
    is_closure: bool = false,
};

/// Returns the number of documented parameters for a function, excluding `*Context` (if has_context), self (if is_method),
/// and capture pointer (if is_closure). `VarArgs` is counted as a normal argument.
pub fn actualArgCount(comptime fn_info: std.builtin.Type.Fn, comptime config: ArgConfig) usize {
    comptime var skip: usize = 0;
    if (config.has_context) skip += 1;
    if (config.is_closure) skip += 1; // capture param
    if (config.is_method) skip += 1; // self param
    const total = fn_info.params.len;
    if (total < skip) return 0;
    return total - skip;
}

/// Returns the documented parameter types for a function, excluding `*Context`, self, and capture pointer.
pub fn actualArgs(comptime fn_info: std.builtin.Type.Fn, comptime config: ArgConfig) [actualArgCount(fn_info, config)]type {
    comptime var types: [actualArgCount(fn_info, config)]type = undefined;
    comptime var out: usize = 0;
    comptime var skip: usize = 0;
    if (config.has_context) skip += 1;
    if (config.is_closure) skip += 1;
    if (config.is_method) skip += 1;
    inline for (fn_info.params[skip..]) |param| {
        const T = param.type orelse continue;
        types[out] = T;
        out += 1;
    }
    return types;
}

test {
    std.testing.refAllDecls(@This());
}
