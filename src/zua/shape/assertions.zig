//! Compile-time assertion helpers for shape declarations. Each function
//! emits a clear compile error when a `ZUA_SHAPE` declaration uses types,
//! methods, or strategies that are incompatible or malformed.

const std = @import("std");
const Marker = @import("../marker.zig");

/// Compile-time assertion that `T` is a struct, union, enum, or opaque type.
///
/// Emits a compile error if the type does not support field mapping or
/// strategy-based metadata.
///
/// Arguments:
/// - T: The type to validate.
pub fn assertContainerType(comptime T: type) void {
    const info = @typeInfo(T);
    if (comptime info != .@"struct" and info != .@"union" and info != .@"enum" and info != .@"opaque") {
        @compileError(@typeName(T) ++ " is not a struct, union, enum, or opaque type and cannot be used with meta strategies that require field mapping");
    }
}

/// Compile-time assertion that `methods` is a struct type.
pub fn assertMethodsIsStruct(comptime methods: anytype) void {
    if (comptime @typeInfo(@TypeOf(methods)) != .@"struct") {
        @compileError("methods must be a struct literal, got " ++ @typeName(@TypeOf(methods)));
    }
}

/// Compile-time validation that each method field is valid.
///
/// Each field must be a raw Zig function or a `Shape.Fn`/`Shape.Closure` wrapper
/// (a type carrying the `native_function` marker). Nested structs and non-callable
/// values are rejected with a clear error naming the field.
pub fn assertValidMethods(comptime methods: anytype) void {
    inline for (@typeInfo(@TypeOf(methods)).@"struct".fields) |field| {
        const T = field.type;
        if (comptime @typeInfo(T) == .@"fn") continue;
        if (comptime Marker.isNativeFunction(T)) continue;
        if (comptime @typeInfo(T) == .type) {
            const val = @field(methods, field.name);
            if (Marker.isNativeFunction(val)) continue;
        }
        @compileError("method `" ++ field.name ++ "` must be a Zig function or Shape.Fn/Closure wrapper, got " ++ @typeName(T));
    }
}

/// Compile-time assertion that `T`, if a union, is a tagged union.
///
/// Untagged unions cannot use `.table` strategy; they must use `.object` or
/// `.ptr` instead.
///
/// Arguments:
/// - T: The type to validate.
pub fn assertTaggedIfUnion(comptime T: type) void {
    if (comptime @typeInfo(T) == .@"union" and @typeInfo(T).@"union".tag_type == null) {
        @compileError(@typeName(T) ++ " is an untagged union, use Shape.Object or Shape.Ptr instead");
    }
}

/// Compile-time assertion that user-provided methods do not shadow
/// auto-generated list methods (`get`, `iter`, `__index`, `__len`).
///
/// Arguments:
/// - methods: A comptime struct of method name–function pairs.
pub fn assertNoListCollisions(comptime methods: anytype) void {
    const reserved = [_][]const u8{ "get", "iter", "__index", "__len" };
    inline for (@typeInfo(@TypeOf(methods)).@"struct".fields) |field| {
        inline for (reserved) |name| {
            if (comptime std.mem.eql(u8, field.name, name))
                @compileError("List already generates '" ++ name ++ "'; remove it from methods or use Object instead");
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
