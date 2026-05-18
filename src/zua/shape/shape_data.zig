//! Compile-time metadata builder for `ZUA_SHAPE` declarations. Produces
//! the struct type that carries a type's translation strategy, hooks,
//! methods, and documentation fields. The encoder, decoder, and docs
//! generator query this metadata through `getMeta` and `strategyOf`.

const std = @import("std");
const builtin = @import("builtin");
const lua = @import("../../lua/lua.zig");

const EncodeHookType = @import("./helpers.zig").EncodeHookType;
const DecodeHookType = @import("./helpers.zig").DecodeHookType;
const DocsHookType = @import("./helpers.zig").DocsHookType;
const Options = @import("options.zig");
const Mapper = @import("../mapper/api.zig");
const Primitive = Mapper.Primitive;
const Context = @import("../context.zig");
const Assertions = @import("./assertions.zig");
const Marker = @import("../marker.zig").Marker;
const Trampoline = @import("./trampoline.zig");

pub const MappingStrategy = enum {
    default,
    table,
    alias,
    typed_alias,
    object,
    ptr,
    closure,
    function,
};

/// Returns the concrete options type for a given strategy and type.
/// Each strategy has its own options struct with only the fields that
/// are relevant for that shape.
pub fn ShapeOptions(comptime Type: type, comptime strategy: MappingStrategy) type {
    const T = if (@hasDecl(Type, "__ZUA_DEFAULT_GUARD_ORIGINAL_TYPE")) Type.__ZUA_DEFAULT_GUARD_ORIGINAL_TYPE else Type;
    return switch (strategy) {
        .default => Options.ObjectOptions,
        .table => Options.TableOptions(T),
        .alias => Options.AliasOptions(T),
        .typed_alias => Options.TypedAliasOptions(T),
        .object => Options.ObjectOptions,
        .ptr => Options.PtrOptions,
        .closure => Trampoline.FnOptions,
        .function => Options.ObjectOptions,
    };
}

/// Low-level shape builder. Prefer the typed helpers in `zua.Shape`.
///
/// Produces a comptime-only type carrying the translation strategy, hooks,
/// methods, and options for a `ZUA_SHAPE` declaration. The returned type
/// is never instantiated. It is queried at compile time by the encoder,
/// decoder, and docs generator.
///
/// All stable strategy, hook, and options combinations are exposed through
/// the typed helpers in `zua.Shape`. Using `Shape` directly with non-standard
/// combinations can lead to unexpected behavior. Do not reach for this unless
/// you know what you are doing.
///
/// Arguments:
/// - Type: The original Zig type the shape describes.
/// - ProxyType: Intermediate representation during encode.
///   `void` for most strategies; `StrAlias` uses `[]const u8`.
/// - strategy: The mapping strategy.
/// - encode_hook: Optional encode hook. `null` produces a no-op default.
/// - decode_hook: Optional decode hook. `null` produces a no-op default.
/// - methods: Comptime struct of method name-function pairs.
/// - options: Per-strategy options (name, description, and strategy-
///   specific fields like field_descriptions or alias_descriptions).
pub fn Shape(
    comptime Type: type,
    comptime ProxyType: type,
    comptime strategy: MappingStrategy,
    comptime encode_hook: ?EncodeHookType(Type, ProxyType),
    comptime decode_hook: ?DecodeHookType(Type),
    comptime methods: anytype,
    comptime options: ShapeOptions(Type, strategy),
    comptime docs_hook: ?DocsHookType(),
) type {
    if (comptime !@hasDecl(Type, "ZUA_SHAPE") and !Marker.isDefaultGuard(Type)) {
        @compileError(@typeName(Type) ++ " has no visible ZUA_SHAPE: is it misspelled or declared outside the type?");
    }

    const T = if (@hasDecl(Type, "__ZUA_DEFAULT_GUARD_ORIGINAL_TYPE")) Type.__ZUA_DEFAULT_GUARD_ORIGINAL_TYPE else Type;

    const encode_hook_typed: ?EncodeHookType(T, ProxyType) = if (encode_hook) |h| @as(EncodeHookType(T, ProxyType), h) else null;
    const decode_hook_typed: ?DecodeHookType(T) = if (decode_hook) |h| @as(DecodeHookType(T), h) else null;

    return struct {
        pub const Strategy = strategy;
        pub const Proxy = ProxyType;
        pub const Methods = if (@typeInfo(@TypeOf(methods)) != .@"struct") .{} else methods;
        pub const EncodeHook: ?EncodeHookType(T, ProxyType) = encode_hook_typed;
        pub const DecodeHook: ?DecodeHookType(T) = decode_hook_typed;
        pub const Options = options;
        pub const DocsHook: ?DocsHookType() = docs_hook;

        /// Attach a custom encode hook.
        ///
        /// The hook converts `T` into `ProxyType` before the value is pushed to Lua.
        pub inline fn withEncode(
            comptime NewProxyType: type,
            comptime handler: EncodeHookType(T, NewProxyType),
        ) type {
            if (comptime strategy == .closure)
                @compileError("closure strategy type " ++ @typeName(T) ++ " does not support encode hook");
            return comptime Shape(T, NewProxyType, strategy, handler, decode_hook, methods, options, null);
        }

        /// Attach a custom decode hook.
        ///
        /// The hook converts a Lua primitive into `T`.
        pub inline fn withDecode(
            comptime handler: DecodeHookType(T),
        ) type {
            if (comptime strategy == .closure)
                @compileError("closure strategy type " ++ @typeName(T) ++ " does not support decode hook");

            return comptime Shape(T, ProxyType, strategy, encode_hook, handler, methods, options, null);
        }

        /// Attach a custom docs hook that generates a complete `Doc` entry,
        /// bypassing the default field/method/alias collection.
        ///
        /// The hook receives the `*Docs` generator and returns a fully
        /// populated `Doc` (Alias, Table, Object, etc.) that replaces the
        /// auto-collected entry.
        pub inline fn withDocs(
            comptime handler: DocsHookType(),
        ) type {
            if (comptime strategy == .closure)
                @compileError("closure strategy type " ++ @typeName(T) ++ " does not support docs hook");

            return comptime Shape(T, ProxyType, strategy, encode_hook, decode_hook, methods, options, handler);
        }
    };
}

/// Wraps a type so that `MetaData` can distinguish default metadata from
/// user-declared `ZUA_SHAPE`.
///
/// When `getShape` falls back to the default strategy it wraps the original
/// type in `DefaultGuard`. The guard's `__ZUA_DEFAULT_GUARD_ORIGINAL_TYPE`
/// field lets internal code recover the original type while `MetaData`'s
/// compile-time guard (`@hasDecl(Type, "ZUA_SHAPE")`) correctly identifies
/// these as having no explicit metadata.
///
/// Arguments:
/// - T: The original type to wrap.
///
/// Returns:
/// - type: A struct type with a single `__ZUA_DEFAULT_GUARD_ORIGINAL_TYPE` constant.
pub fn DefaultGuard(comptime T: type) type {
    return struct {
        pub const __ZUA_MARKER = Marker.default_guard;
        const __ZUA_DEFAULT_GUARD_ORIGINAL_TYPE = T;
    };
}

/// Returns the compile-time metadata type for `T`.
///
/// This helper is used internally to determine the metadata layout for a
/// type. It applies the same default rules used by translation and
/// documentation code and returns the metadata type directly.
///
/// Internally this is used by code that needs to compute metadata shape at
/// compile time without materializing a separate metadata value.
pub inline fn getShape(comptime T: type) type {
    if (comptime @typeInfo(T) != .@"struct" and @typeInfo(T) != .@"union" and @typeInfo(T) != .@"enum" and @typeInfo(T) != .@"opaque") {
        return Shape(DefaultGuard(T), void, .default, null, null, null, .{}, null);
    }

    if (comptime @hasDecl(T, "ZUA_SHAPE")) return T.ZUA_SHAPE;
    return switch (@typeInfo(T)) {
        .@"struct" => Shape(DefaultGuard(T), void, .table, null, null, null, .{}, null),
        .@"union" => |u| if (u.tag_type != null) Shape(DefaultGuard(T), void, .alias, null, null, null, .{}, null) else Shape(DefaultGuard(T), void, .object, null, null, null, .{}, null),
        .@"enum" => Shape(DefaultGuard(T), void, .alias, null, null, null, .{}, null),
        .@"opaque" => Shape(DefaultGuard(T), void, .ptr, null, null, null, .{}, null),
        else => @compileError("no default shape for " ++ @typeName(T)),
    };
}

/// Returns the translation strategy declared for `T`.
///
/// This is the main branch point used by translation and docs code to decide
/// whether `T` behaves as a table, userdata object, light userdata pointer,
/// or closure capture.
pub inline fn strategyOf(comptime T: type) MappingStrategy {
    return comptime getShape(T).Strategy;
}

/// Returns the method set exposed by `T`.
///
/// The returned comptime struct is the method table declared on `ZUA_SHAPE`,
/// or an empty struct when `T` exposes no methods.
pub inline fn methodsOf(comptime T: type) @TypeOf(getShape(T).Methods) {
    return comptime getShape(T).Methods;
}

/// Returns the documentation name associated with `T`.
///
/// This is the explicit name attached through the shape options,
/// otherwise the Zig type name.
pub inline fn nameOf(comptime T: type) []const u8 {
    const meta = comptime getShape(T);
    const strategy = meta.Strategy;
    const raw: ?[]const u8 = if (comptime strategy != .closure and strategy != .function) meta.Options.name else null;
    return raw orelse blk: {
        const full: []const u8 = @typeName(T);
        const dot = std.mem.lastIndexOfScalar(u8, full, '.');
        break :blk if (dot) |d| full[d + 1 ..] else full;
    };
}

/// Returns the documentation description associated with `T`.
///
/// This is empty unless the metadata type was constructed with a description.
pub inline fn descriptionOf(comptime T: type) []const u8 {
    const meta = comptime getShape(T);
    if (comptime meta.Strategy == .closure) {
        return meta.Options.description;
    }
    return meta.Options.description orelse "";
}

/// Returns the proxy type used by `T`'s encode hook.
///
/// For most strategies this is `void`, but helpers such as `StrAlias()` use a
/// concrete proxy type like `[]const u8` to describe the value pushed into Lua
/// when a custom encode hook is active.
pub inline fn proxyTypeOf(comptime T: type) type {
    return comptime getShape(T).Proxy;
}

/// Returns the field descriptions for a `.table` strategy type.
pub inline fn attributeDescriptionsOf(comptime T: type) Options.FieldDescriptions(T) {
    const meta = comptime getShape(T);
    if (comptime meta.Strategy == .table) {
        return meta.Options.field_descriptions orelse @as(Options.FieldDescriptions(T), .{});
    }
    return @as(Options.FieldDescriptions(T), .{});
}

/// Returns the alias descriptions for a `.alias` strategy type.
pub inline fn aliasDescriptionsOf(comptime T: type) Options.AliasDescriptions(T) {
    const meta = comptime getShape(T);
    if (comptime meta.Strategy == .alias) {
        return meta.Options.alias_descriptions orelse @as(Options.AliasDescriptions(T), .{});
    }
    return @as(Options.AliasDescriptions(T), .{});
}

/// Returns the variant descriptions for a `.typed_alias` strategy type.
pub inline fn variantDescriptionsOf(comptime T: type) Options.VariantDescriptions(T) {
    const meta = comptime getShape(T);
    if (comptime meta.Strategy == .typed_alias) {
        return meta.Options.variant_descriptions orelse @as(Options.VariantDescriptions(T), .{});
    }
    return @as(Options.VariantDescriptions(T), .{});
}

/// Returns the Lua CFunction trampoline for types with `.function` strategy.
/// Returns `null` if the type has no native function trampoline.
pub inline fn trampolineOf(comptime T: type) ?lua.CFunction {
    if (comptime strategyOf(T) == .function) {
        return comptime T.ZUA_SHAPE.trampoline();
    }
    return null;
}

/// Returns `true` if `T` has a `.function` strategy (native function
/// wrapper or struct wrapping one).
pub inline fn isFunction(comptime T: type) bool {
    return comptime trampolineOf(T) != null;
}



test {
    std.testing.refAllDecls(@This());
}
