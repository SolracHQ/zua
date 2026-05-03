//! Metadata for a Zig type that is translated to Lua.
//!
//! This module centralizes translation strategy, custom encode/decode hooks,
//! and method metadata so translation code does not need to replicate fallbacks.
//! `getMeta(T)` is the single entry point for retrieving the metadata type for
//! a translated Zig type.

const std = @import("std");
const Mapper = @import("../mapper/mapper.zig");
const Primitive = Mapper.Decoder.Primitive;
const Context = @import("../state/context.zig");

/// The mapping strategy determines how a Zig type is represented in Lua and what methods it supports. The strategy is the primary piece of metadata used by
/// translation code to implement the correct behavior for a type, and it also informs documentation generation.
pub const MappingStrategy = enum {
    /// The value is represented as a Lua table.
    table,

    /// The value is represented as userdata with a metatable.
    object,

    /// The value is represented as light userdata.
    ptr,

    /// The value is stored as upvalue 1 of a Lua C closure.
    /// Used only in conjunction with `Native.closure`. The struct is
    /// allocated as userdata inside the closure and injected as a `*T`
    /// parameter into the callback. Encode/decode hooks are not supported.
    capture,
};

/// Internal alias for a custom encode hook signature.
///
/// This helper is used by `MetaData` to represent encode hooks that take the
/// current call `Context` and a Zig value of type `T`, then return a proxy type
/// to push into Lua.
///
/// In the case the developer wants to only encode certain values but continue with
/// the default path for others can just return null to indicate the default encoding should be used.
///
/// the optional return also allow use the hook to transform the value returning the same type but with different content,
/// for example to implement a custom string encoding for a struct while still pushing it as a table.
pub fn EncodeHookType(comptime T: type, comptime ProxyType: type) type {
    return fn (*Context, T) anyerror!?ProxyType;
}

/// Internal alias for a custom decode hook signature.
///
/// This helper represents a hook that receives a Lua `Primitive` and the
/// current evaluation `Context`, then returns a decoded `T` or fails.
///
/// In the case the developer wants to only decode certain primitives but
/// continue with the default path for others can just return null to indicate the default decoding should be used.
pub fn DecodeHookType(comptime T: type) type {
    return fn (*Context, Primitive) anyerror!?T;
}

/// Returns a per-variant info struct type that carries `field_descriptions`
/// matching the variant's field type.
pub fn VariantInfoType(comptime FieldType: type) type {
    const fd_type = FieldDescriptions(FieldType);
    return struct {
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
        field_descriptions: fd_type = .{},
    };
}

/// Generates a struct type whose fields match `T`'s struct fields, each typed as
/// `?[]const u8` for documentation descriptions.
pub fn FieldDescriptions(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .@"struct") {
        const fields = info.@"struct".fields;
        if (fields.len == 0) return @Struct(.auto, null, &.{}, &.{}, &.{});
        var names: [fields.len][]const u8 = undefined;
        var types: [fields.len]type = undefined;
        var attributes: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
        for (fields, 0..) |field, i| {
            names[i] = field.name;
            types[i] = ?[]const u8;
            attributes[i] = .{
                .default_value_ptr = &@as(?[]const u8, null),
            };
        }
        return @Struct(.auto, null, &names, &types, &attributes);
    }
    return @Struct(.auto, null, &.{}, &.{}, &.{});
}

/// Generates a struct type whose fields match `T`'s tagged union variants,
/// each typed with per-variant info including `field_descriptions` for the
/// variant's field type.
pub fn VariantDescriptions(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .@"union" and info.@"union".tag_type != null) {
        const fields = info.@"union".fields;
        if (fields.len == 0) return @Struct(.auto, null, &.{}, &.{}, &.{});

        var names: [fields.len][]const u8 = undefined;
        var types: [fields.len]type = undefined;
        var attributes: [fields.len]std.builtin.Type.StructField.Attributes = undefined;
        for (fields, 0..) |field, i| {
            const InfoType = VariantInfoType(field.type);
            names[i] = field.name;
            types[i] = InfoType;
            attributes[i] = .{
                .default_value_ptr = &@as(InfoType, .{}),
            };
        }
        return @Struct(.auto, null, &names, &types, &attributes);
    }
    return @Struct(.auto, null, &.{}, &.{}, &.{});
}

/// Documentation options for a metadata type.
///
/// For `.table` strategy types, includes `field_descriptions` for structs or
/// `variants` for tagged unions, generated from `T`.
pub fn MetaOptions(comptime T: type, comptime strategy: MappingStrategy) type {
    if (comptime strategy == .table and @typeInfo(T) == .@"union" and @typeInfo(T).@"union".tag_type != null) {
        return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            variants: VariantDescriptions(T) = .{},
        };
    } else if (comptime strategy == .table) {
        return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            field_descriptions: FieldDescriptions(T) = .{},
        };
    }
    return struct {
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
    };
}

pub const Object = strategies.Object;
pub const Table = strategies.Table;
pub const Ptr = strategies.Ptr;
pub const Capture = strategies.Capture;
pub const List = strategies.List;
pub const strEnum = strategies.strEnum;

pub const getMeta = metadata.getMeta;
pub const strategyOf = metadata.strategyOf;
pub const methodsOf = metadata.methodsOf;
pub const nameOf = metadata.nameOf;
pub const descriptionOf = metadata.descriptionOf;
pub const proxyTypeOf = metadata.proxyTypeOf;
pub const attributeDescriptionsOf = metadata.attributeDescriptionsOf;
pub const variantDescriptionsOf = metadata.variantDescriptionsOf;

const helpers = @import("./helpers.zig");
const metadata = @import("./metadata.zig");
const strategies = @import("./strategies.zig");

test {
    std.testing.refAllDecls(@This());
}
