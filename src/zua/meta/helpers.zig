const std = @import("std");
const meta = @import("./meta.zig");
const Mapper = @import("../mapper/mapper.zig");
const Primitive = Mapper.Decoder.Primitive;
const Context = @import("../state/context.zig");

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

/// Compile-time assertion that `T`, if a union, is a tagged union.
///
/// Untagged unions cannot use `.table` strategy; they must use `.object` or
/// `.ptr` instead.
///
/// Arguments:
/// - T: The type to validate.
pub fn assertTaggedIfUnion(comptime T: type) void {
    if (comptime @typeInfo(T) == .@"union" and @typeInfo(T).@"union".tag_type == null) {
        @compileError(@typeName(T) ++ " is an untagged union, use meta.Object or meta.Ptr instead");
    }
}

/// Builds an encode hook that converts an enum value to its `@tagName` string.
///
/// The returned function pointer is used by `Meta.strEnum` to push enum
/// values as Lua strings.
///
/// Arguments:
/// - T: The enum type to encode.
///
/// Returns:
/// - An encode hook function pointer for use in `MetaData`.
pub fn strEnumEncode(comptime T: type) meta.EncodeHookType(T, []const u8) {
    return struct {
        fn encode(_: *Context, value: T) !?[]const u8 {
            return @tagName(value);
        }
    }.encode;
}

/// Builds a decode hook that parses a Lua string back into an enum value.
///
/// Matches the input string against enum field names. Fails with a typed
/// error when the string does not match any variant.
///
/// Arguments:
/// - T: The enum type to decode into.
///
/// Returns:
/// - A decode hook function pointer for use in `MetaData`.
pub fn strEnumDecode(comptime T: type) meta.DecodeHookType(T) {
    return struct {
        fn decode(ctx: *Context, primitive: Primitive) anyerror!?T {
            const str = switch (primitive) {
                .string => |s| s,
                else => return ctx.failTyped(?T, "expected string"),
            };
            inline for (std.meta.fields(T)) |field| {
                if (std.mem.eql(u8, str, field.name)) return @field(T, field.name);
            }
            return ctx.failTyped(?T, "invalid enum value");
        }
    }.decode;
}

/// Resolves the element type from a `getElements` accessor function.
///
/// The function must return a slice; the element type is the slice's child
/// type. Emits a compile error if the return type is not a slice.
///
/// Arguments:
/// - getElements: A function returning `[]const T` or `[]T`.
///
/// Returns:
/// - type: The element type `T`.
pub fn ElementType(comptime getElements: anytype) type {
    const R = @typeInfo(@TypeOf(getElements)).@"fn".return_type orelse
        @compileError("getElements must have an explicit return type");
    const info = @typeInfo(R);
    if (info != .pointer or info.pointer.size != .slice)
        @compileError("getElements must return a slice type, got " ++ @typeName(R));
    return info.pointer.child;
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

/// Merges two method struct types into a single type containing all fields
/// from both. Duplicate names are not checked; `b`'s fields are appended
/// after `a`'s.
///
/// Arguments:
/// - a: First method struct.
/// - b: Second method struct.
///
/// Returns:
/// - type: A struct type with all fields from `a` followed by all fields from `b`.
pub fn mergeMethodType(comptime a: anytype, comptime b: anytype) type {
    const fa = @typeInfo(@TypeOf(a)).@"struct".fields;
    const fb = @typeInfo(@TypeOf(b)).@"struct".fields;

    var names: [fa.len + fb.len][]const u8 = undefined;
    var types: [fa.len + fb.len]type = undefined;
    var attributes: [fa.len + fb.len]std.builtin.Type.StructField.Attributes = undefined;
    var n = 0;
    for (fa) |field| {
        names[n] = field.name;
        types[n] = field.type;
        attributes[n] = .{
            .@"comptime" = field.is_comptime,
            .@"align" = field.alignment,
            .default_value_ptr = field.default_value_ptr,
        };
        n += 1;
    }
    for (fb) |field| {
        names[n] = field.name;
        types[n] = field.type;
        attributes[n] = .{
            .@"comptime" = field.is_comptime,
            .@"align" = field.alignment,
            .default_value_ptr = field.default_value_ptr,
        };
        n += 1;
    }
    return @Struct(.auto, null, &names, &types, &attributes);
}

/// Merges two method struct values into a single value. Fields from `b`
/// override `a` only when the merge type contains both (struct auto merge).
///
/// Arguments:
/// - a: First method set value.
/// - b: Second method set value.
///
/// Returns:
/// - A merged value of `mergeMethodType(a, b)`.
pub fn mergeMethodSets(comptime a: anytype, comptime b: anytype) mergeMethodType(a, b) {
    const R = mergeMethodType(a, b);
    var result: R = undefined;
    const fa = @typeInfo(@TypeOf(a)).@"struct".fields;
    const fb = @typeInfo(@TypeOf(b)).@"struct".fields;
    inline for (fa) |f| @field(result, f.name) = @field(a, f.name);
    inline for (fb) |f| @field(result, f.name) = @field(b, f.name);
    return result;
}

/// Generates a struct type with auto-implemented list methods (`get`,
/// `__index`, `__len`, `iter`) for a list-object-backed type `L`.
///
/// The generated methods delegate to `getElements` for element access and
/// 1-indexed Lua conventions.
///
/// Arguments:
/// - L: The userdata type that owns the list.
/// - getElements: An accessor returning `[]const T`.
///
/// Returns:
/// - type: A struct type with `get`, `__index`, `__len`, and `iter` methods.
pub fn generatedListMethods(comptime L: type, comptime getElements: anytype) type {
    const T = ElementType(getElements);
    const Handlers = @import("../handlers/handlers.zig");
    const Native = @import("../functions/native.zig");

    return struct {
        pub fn get(self: *L, index: usize) ?T {
            if (index == 0) return null;
            const elems = getElements(self);
            if (index - 1 < elems.len) return elems[index - 1];
            return null;
        }

        pub fn __index(self: *L, index: usize) ?T {
            return get(self, index);
        }

        pub fn __len(self: *L, _: *L) usize {
            return getElements(self).len;
        }

        fn iget(self: *L, index: usize) !struct { ?usize, ?T } {
            const elem = get(self, index + 1);
            const next = if (elem != null) index + 1 else null;
            return .{ next, elem };
        }

        pub fn iter(self: Handlers.Userdata) struct {
            Native.NativeFn(iget, .{}, .{}),
            Handlers.Userdata,
            ?usize,
        } {
            return .{ .{}, self, 0 };
        }
    };
}

/// Generates a concrete set of list method values for registration in
/// `ZUA_META`. Delegates to `generatedListMethods` and extracts the four
/// standard list methods (`get`, `__index`, `__len`, `iter`) into a
/// comptime struct literal.
///
/// Arguments:
/// - L: The userdata type that owns the list.
/// - getElements: An accessor returning `[]const T`.
///
/// Returns:
/// - A struct value with `get`, `__index`, `__len`, and `iter` fields.
pub fn generateListMethodsSet(comptime L: type, comptime getElements: anytype) @TypeOf(.{
    .get = generatedListMethods(L, getElements).get,
    .__index = generatedListMethods(L, getElements).__index,
    .__len = generatedListMethods(L, getElements).__len,
    .iter = generatedListMethods(L, getElements).iter,
}) {
    return .{
        .get = generatedListMethods(L, getElements).get,
        .__index = generatedListMethods(L, getElements).__index,
        .__len = generatedListMethods(L, getElements).__len,
        .iter = generatedListMethods(L, getElements).iter,
    };
}

/// Returns whether `T` is a NativeFn/Closure wrapper type (has the
/// `__IsZuaNativeFunction` marker).
pub fn isNativeWrapperType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "__IsZuaNativeFunction");
}

/// Returns whether `T` is a pointer to a capture-strategy type.
pub fn isCapturePointer(comptime T: type) bool {
    if (@typeInfo(T) != .pointer) return false;
    const ptr = @typeInfo(T).pointer;
    if (ptr.size != .one) return false;
    const Child = ptr.child;
    return meta.strategyOf(Child) == .capture;
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
        if (info == .@"struct" and info.@"struct".is_tuple) return spec[index];
        if (index == 0) return spec;
        @compileError("typeListAt index out of bounds for non-tuple type " ++ @typeName(spec));
    }
    return spec[index];
}

/// Returns whether `T` is a struct type with a declaration named `name`.
pub fn hasStructDecl(comptime T: type, comptime name: []const u8) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, name);
}

test {
    std.testing.refAllDecls(@This());
}
