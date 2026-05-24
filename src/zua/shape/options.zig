//! Options structs for each shape strategy.
//! Each strategy declares its own options type through `Shape.Options.*`
//! so callers see exactly the fields they can set. `Fn` and `ArgInfo`
//! describe Zig function parameters for Lua stub generation.

const std = @import("std");
const Trampoline = @import("trampoline.zig");

pub const Fn = Trampoline.FnOptions;

pub const ArgInfo = Trampoline.ArgInfo;

/// Generates a struct type with one `?[]const u8` field per struct field
/// of `T`. Used by `TableOptions.field_descriptions` to attach
/// documentation strings to individual struct fields.
pub fn FieldDescriptions(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .@"struct") {
        const fields = info.@"struct".fields;
        if (fields.len == 0) return struct {};
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
    return struct {};
}

/// Generates a struct type with one `?[]const u8` field per enum variant
/// of `T`. Used by `AliasOptions.alias_descriptions` to attach
/// documentation strings to individual enum variants.
pub fn AliasDescriptions(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .@"enum") {
        const fields = info.@"enum".fields;
        if (fields.len == 0) return struct {};
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
    return struct {};
}

/// Per-variant metadata type used by `VariantDescriptions`. Each
/// variant can optionally set a custom display `name`, a `description`,
/// and `field_descriptions` for the variant's payload struct fields.
pub fn VariantInfoType(comptime FieldType: type) type {
    const fd_type = FieldDescriptions(FieldType);
    return struct {
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
        field_descriptions: fd_type = .{},
    };
}

/// Generates a struct type describing each variant of a tagged union `T`.
/// Each field maps to a union variant and carries a `VariantInfoType`
/// value with optional name, description, and field descriptions.
pub fn VariantDescriptions(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .@"union" and info.@"union".tag_type != null) {
        const fields = info.@"union".fields;
        if (fields.len == 0) return struct {};
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
    return struct {};
}

/// Options for `Shape.Table`. Accepts an optional name, description,
/// and per-field documentation strings.
pub fn TableOptions(comptime T: type) type {
    return struct {
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
        field_descriptions: ?FieldDescriptions(T) = null,
    };
}

/// Options for `Shape.Alias` and `Shape.StrAlias`. Accepts an optional
/// name, description, and per-variant documentation strings for enums.
pub fn AliasOptions(comptime T: type) type {
    return struct {
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
        alias_descriptions: ?AliasDescriptions(T) = null,
    };
}

/// Options for `Shape.TypedAlias`. Accepts an optional name, description,
/// and per-variant metadata (custom name, description, field descriptions).
pub fn TypedAliasOptions(comptime T: type) type {
    return struct {
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
        variant_descriptions: ?VariantDescriptions(T) = null,
    };
}

/// Options for `Shape.Object`. Accepts an optional name and description.
pub const ObjectOptions = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Options for `Shape.Ptr`. Accepts an optional name and description.
pub const PtrOptions = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

test {
    std.testing.refAllDecls(@This());
}
