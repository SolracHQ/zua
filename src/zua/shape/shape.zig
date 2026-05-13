//! How a Zig type looks from the Lua side.
//!
//! Each shape declares a Lua representation for a Zig type:
//! - `Shape.Object(T, methods, options)` — userdata with identity and methods
//! - `Shape.Table(T, methods, options)` — struct/union as a Lua table
//! - `Shape.Ptr(T, options)` — opaque light userdata handle
//! - `Shape.Closure(T, callback, methods)` — struct as a callable CClosure
//! - `Shape.List(T, getElements, methods, options)` — sequence-like userdata
//! - `Shape.strEnum(T, methods, options)` — enum as string values
//! - `Shape.Fn(fn, options)` — wrap a Zig function for Lua callers
//!
//! Customize encoding with `.withEncode(ProxyType, encodeFn)` and decoding
//! with `.withDecode(decodeFn)`. Override doc generation with `.withDocs(hook)`.

const std = @import("std");
const Mapper = @import("../mapper/mapper.zig");
const Primitive = Mapper.Primitive;
const Context = @import("../state/context.zig");
const docs = @import("../docs/docs.zig");
const internal_fields = @import("metadata.zig");

/// Signature for a custom encode hook: `fn (*Context, T) !?ProxyType`.
/// Return `null` to fall through to the default encoding.
pub fn EncodeHookType(comptime T: type, comptime ProxyType: type) type {
    return fn (*Context, T) anyerror!?ProxyType;
}

/// Signature for a custom decode hook: `fn (*Context, Primitive) !?T`.
/// Return `null` to fall through to the default decoding.
pub fn DecodeHookType(comptime T: type) type {
    return fn (*Context, Primitive) anyerror!?T;
}

/// Signature for a custom docs hook: `fn (*Docs) !void`.
/// Bypasses the default field/method/alias collection.
pub fn DocsHookType(comptime _: type) type {
    return fn (*docs) anyerror!void;
}

/// Options for declaring a shape's name, description, and per-field docs.
/// Shape-specific variants include `field_descriptions` or `variants`.
pub fn MetaOptions(comptime T: type, comptime strategy: internal_fields.MappingStrategy) type {
    if (comptime strategy == .table and @typeInfo(T) == .@"union" and @typeInfo(T).@"union".tag_type != null) {
        return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            variants: internal_fields.VariantDescriptions(T) = .{},
        };
    } else if (comptime strategy == .table) {
        return struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            field_descriptions: internal_fields.FieldDescriptions(T) = .{},
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
pub const List = strategies.List;
pub const strEnum = strategies.strEnum;
pub const Closure = strategies.Closure;

pub const Fn = @import("fn.zig").Fn;
pub const FnOptions = @import("fn.zig").FnOptions;
pub const ArgInfo = @import("fn.zig").ArgInfo;

const strategies = @import("./strategies.zig");

test {
    std.testing.refAllDecls(@This());
}
