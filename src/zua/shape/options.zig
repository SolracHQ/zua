//! Options for shape constructors and function wrappers. The strategy
//! constructors (`Object`, `Table`, `Ptr`) take a `MetaOptions` parameter
//! that adapts its fields depending on the shape. `Fn` and `ArgInfo`
//! describe Zig function parameters for Lua stub generation.

const std = @import("std");
const Metadata = @import("metadata.zig");
const Trampoline = @import("trampoline.zig");

pub const Fn = Trampoline.FnOptions;

pub const ArgInfo = Trampoline.ArgInfo;

/// Options for declaring a shape's name, description, and per-field docs.
/// Shape-specific variants include `field_descriptions` or `variants`.
pub fn MetaOptions(comptime T: type, comptime strategy: Metadata.MappingStrategy) type {
    if (comptime strategy == .table and @typeInfo(T) == .@"union" and @typeInfo(T).@"union".tag_type != null) {
        return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            variants: Metadata.VariantDescriptions(T) = .{},
        };
    } else if (comptime strategy == .table) {
        return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            field_descriptions: Metadata.FieldDescriptions(T) = .{},
        };
    }
    return struct {
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
    };
}

test {
    std.testing.refAllDecls(@This());
}
