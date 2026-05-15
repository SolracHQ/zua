//! Shared hook type signatures and generators for the Shape module.
//! Used internally by `MetaData` to type-check encode, decode, and docs
//! hooks. Also provides compile-time helpers for merging method sets
//! and generating list method implementations.

const std = @import("std");
const Trampoline = @import("trampoline.zig");
const Context = @import("../context.zig");
const Mapper = @import("../mapper/api.zig");
const Primitive = Mapper.Primitive;
const Handlers = @import("../handlers/api.zig");
const Gen = @import("../docs/generator.zig").Generator;
pub fn EncodeHookType(comptime T: type, comptime ProxyType: type) type {
    return fn (*Context, T) anyerror!?ProxyType;
}

pub fn DecodeHookType(comptime T: type) type {
    return fn (*Context, Primitive) anyerror!?T;
}

pub fn DocsHookType(comptime _: type) type {
    return fn (*Gen) anyerror!void;
}

/// Builds an encode hook that converts an enum value to its `@tagName` string.
///
/// The returned function pointer is used by `Shape.StrEnum` to push enum
/// values as Lua strings.
///
/// Arguments:
/// - T: The enum type to encode.
///
/// Returns:
/// - An encode hook function pointer for use in `MetaData`.
pub fn strEnumEncode(comptime T: type) EncodeHookType(T, []const u8) {
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
pub fn strEnumDecode(comptime T: type) DecodeHookType(T) {
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

        pub fn iter(self: Handlers.Any.Userdata) struct {
            Trampoline.makeFn(iget, false, .{}),
            Handlers.Any.Userdata,
            ?usize,
        } {
            return .{ .{}, self, 0 };
        }
    };
}

/// Generates a concrete set of list method values for registration in
/// `ZUA_SHAPE`. Delegates to `generatedListMethods` and extracts the four
/// standard list methods (`get`, `__index`, `__len`, `iter`) into a
/// comptime struct literal, wrapping public-facing methods with documentation.
///
/// Arguments:
/// - L: The userdata type that owns the list.
/// - getElements: An accessor returning `[]const T`.
///
/// Returns:
/// - A struct value with `get`, `__index`, `__len`, and `iter` fields.
pub fn generateListMethodsSet(comptime L: type, comptime getElements: anytype) @TypeOf(blk: {
    const ListGen = generatedListMethods(L, getElements);
    break :blk .{
        .get = Trampoline.makeFn(ListGen.get, false, .{
            .description = "Returns the element at the given 1-based index.",
            .args = &.{
                .{ .name = "index", .description = "1-based index." },
            },
        }){},
        .__index = ListGen.__index,
        .__len = ListGen.__len,
        .iter = Trampoline.makeFn(ListGen.iter, false, .{
            .description = "Returns an iterator compatible with Lua for..in syntax.",
        }){},
    };
}) {
    const ListGen = generatedListMethods(L, getElements);
    return .{
        .get = Trampoline.makeFn(ListGen.get, false, .{
            .description = "Returns the element at the given 1-based index.",
            .args = &.{
                .{ .name = "index", .description = "1-based index." },
            },
        }){},
        .__index = ListGen.__index,
        .__len = ListGen.__len,
        .iter = Trampoline.makeFn(ListGen.iter, false, .{
            .description = "Returns an iterator compatible with Lua for..in syntax.",
        }){},
    };
}

test {
    std.testing.refAllDecls(@This());
}
