const std = @import("std");
const meta = @import("./meta.zig");
const Mapper = @import("../mapper/mapper.zig");
const Primitive = Mapper.Decoder.Primitive;
const Context = @import("../state/context.zig");
const helpers = @import("helpers.zig");

/// Constructs the compile-time metadata type for `ZUA_META`.
///
/// This is the low-level builder that all strategy helpers (`Object`, `Table`,
/// `Ptr`, `Capture`) delegate to. It produces a struct type with the constants
/// that translation, documentation, and stub-generation code query at compile
/// time.
///
/// Most types should use the strategy helpers in `zua.Meta` instead of calling
/// `MetaData` directly. Use `MetaData` directly only when you need to customize
/// the proxy type, encode hook, or decode hook in ways the helpers do not
/// expose.
///
/// The returned type has these public members:
/// - `Strategy` — the `MappingStrategy` for translation.
/// - `Proxy` — the proxy type used by encode hooks.
/// - `Methods` — the method table exposed to Lua.
/// - `EncodeHook` — a hook converting `T` to `ProxyType`, or a no-op default.
/// - `DecodeHook` — a hook converting a Lua primitive to `T`, or a no-op default.
/// - `Name` — the documentation name (explicit or `@typeName`).
/// - `Description` — the documentation description string.
/// - `AttributeDescriptions` — per-field documentation.
/// - `VariantDescriptions` — per-variant documentation for tagged unions.
///
/// Arguments:
/// - Type: The original Zig type the metadata describes.
/// - ProxyType: The type used as an intermediate representation during encode.
///   Most strategies use `void`; `strEnum` uses `[]const u8`.
/// - strategy: The mapping strategy (table, object, ptr, capture).
/// - encode_hook: Optional encode hook. `null` produces a no-op default.
/// - decode_hook: Optional decode hook. `null` produces a no-op default.
/// - methods: A comptime struct of method name–function pairs, or `null`/`{}`.
/// - options: A `MetaOptions` struct with optional `name`, `description`,
///   `field_descriptions`, and `variants`.
///
/// Returns:
/// - `type`: A struct type suitable for use as `pub const ZUA_META`.
///
/// Example:
/// ```zig
/// pub const ZUA_META = MetaData(MyType, []const u8, .table,
///     MyType.encode, MyType.decode,
///     .{ .__gc = cleanup },
///     .{ .name = "MyType", .description = "Does a thing." },
/// );
/// ```
pub fn MetaData(
    comptime Type: type,
    comptime ProxyType: type,
    comptime strategy: meta.MappingStrategy,
    comptime encode_hook: ?meta.EncodeHookType(Type, ProxyType),
    comptime decode_hook: ?meta.DecodeHookType(Type),
    comptime methods: anytype,
    comptime options: anytype,
) type {
    if (comptime !@hasDecl(Type, "ZUA_META") and !@hasDecl(Type, "__DEFAULT_GUARD_ORIGINAL_TYPE")) {
        @compileError(@typeName(Type) ++ " has no visible ZUA_META: is it misspelled or declared outside the type?");
    }

    const T = if (@hasDecl(Type, "__DEFAULT_GUARD_ORIGINAL_TYPE")) Type.__DEFAULT_GUARD_ORIGINAL_TYPE else Type;

    const opts_name = if (@hasField(@TypeOf(options), "name")) options.name else null;
    const opts_description = if (@hasField(@TypeOf(options), "description")) options.description else null;
    const opts_field_descriptions = if (@hasField(@TypeOf(options), "field_descriptions")) options.field_descriptions else .{};
    const opts_variants = if (@hasField(@TypeOf(options), "variants")) options.variants else .{};

    return struct {
        pub const Strategy = strategy;
        pub const Proxy = ProxyType;
        pub const Methods = if (@typeInfo(@TypeOf(methods)) != .@"struct") .{} else methods;
        pub const EncodeHook: meta.EncodeHookType(T, ProxyType) = encode_hook orelse default_encode;
        pub const DecodeHook: meta.DecodeHookType(T) = decode_hook orelse default_decode;
        pub const Description: []const u8 = opts_description orelse "";
        pub const Name: []const u8 = opts_name orelse @typeName(T);
        pub const AttributeDescriptions = if (@typeInfo(@TypeOf(opts_field_descriptions)) != .@"struct") .{} else opts_field_descriptions;
        pub const VariantDescriptions = if (@typeInfo(@TypeOf(opts_variants)) != .@"struct") .{} else opts_variants;

        fn default_encode(_: *Context, _: T) anyerror!?ProxyType {
            return null;
        }

        fn default_decode(_: *Context, _: Primitive) anyerror!?T {
            return null;
        }

        /// Attach a custom encode hook.
        ///
        /// The hook converts `T` into `ProxyType` before the value is pushed to Lua.
        pub inline fn withEncode(
            comptime NewProxyType: type,
            comptime handler: meta.EncodeHookType(T, NewProxyType),
        ) type {
            if (comptime strategy == .capture)
                @compileError("capture strategy type " ++ @typeName(T) ++ " do not support encode hook");
            return comptime MetaData(T, NewProxyType, strategy, handler, decode_hook, methods, options);
        }

        /// Attach a custom decode hook.
        ///
        /// The hook converts a Lua primitive into `T`.
        pub inline fn withDecode(
            comptime handler: meta.DecodeHookType(T),
        ) type {
            if (comptime strategy == .capture)
                @compileError("capture strategy type " ++ @typeName(T) ++ " do not support decode hook");

            return comptime MetaData(T, ProxyType, strategy, encode_hook, handler, methods, options);
        }
    };
}

/// Wraps a type so that `MetaData` can distinguish default metadata from
/// user-declared `ZUA_META`.
///
/// When `getMeta` falls back to the default strategy (`.table` for structs,
/// `.object` for untagged unions) it wraps the original type in `DefaultGuard`.
/// The guard's `__DEFAULT_GUARD_ORIGINAL_TYPE` field lets internal code recover
/// the original type while `MetaData`'s compile-time guard (`@hasDecl(Type,
/// "ZUA_META")`) correctly identifies these as having no explicit metadata.
///
/// Arguments:
/// - T: The original type to wrap.
///
/// Returns:
/// - type: A struct type with a single `__DEFAULT_GUARD_ORIGINAL_TYPE` constant.
pub fn DefaultGuard(comptime T: type) type {
    return struct {
        pub const __DEFAULT_GUARD_ORIGINAL_TYPE = T;
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
pub inline fn getMeta(comptime T: type) type {
    helpers.assertContainerType(T);
    // Force evaluation of all public declarations in debug builds so
    // misspelled ZUA_META constants are caught at compile time.
    // Skipped in release to preserve lazy evaluation semantics.
    if (comptime @import("builtin").mode == .Debug) {
        inline for (comptime std.meta.declarations(T)) |decl| {
            _ = &@field(T, decl.name);
        }
    }
    const info = @typeInfo(T);
    if (comptime @hasDecl(T, "ZUA_META")) return T.ZUA_META;
    if (comptime info == .@"union" and info.@"union".tag_type == null) return MetaData(DefaultGuard(T), void, .object, null, null, null, .{});
    return MetaData(DefaultGuard(T), void, .table, null, null, null, .{});
}

/// Returns the translation strategy declared for `T`.
///
/// This is the main branch point used by translation and docs code to decide
/// whether `T` behaves as a table, userdata object, light userdata pointer,
/// or closure capture.
pub inline fn strategyOf(comptime T: type) meta.MappingStrategy {
    return comptime getMeta(T).Strategy;
}

/// Returns the method set exposed by `T`.
///
/// The returned comptime struct is the method table declared on `ZUA_META`,
/// or an empty struct when `T` exposes no methods.
pub inline fn methodsOf(comptime T: type) @TypeOf(getMeta(T).Methods) {
    return comptime getMeta(T).Methods;
}

/// Returns the documentation name associated with `T`.
///
/// This is the explicit name attached with `MetaOptions` when present,
/// otherwise the Zig type name.
pub inline fn nameOf(comptime T: type) []const u8 {
    return comptime getMeta(T).Name;
}

/// Returns the documentation description associated with `T`.
///
/// This is empty unless the metadata type was constructed with a description.
pub inline fn descriptionOf(comptime T: type) []const u8 {
    return comptime getMeta(T).Description;
}

/// Returns the proxy type used by `T`'s encode hook.
///
/// For most strategies this is `void`, but helpers such as `strEnum()` use a
/// concrete proxy type like `[]const u8` to describe the value pushed into Lua
/// when a custom encode hook is active.
pub inline fn proxyTypeOf(comptime T: type) type {
    return comptime getMeta(T).Proxy;
}

/// Returns the attribute descriptions attached to `T`.
///
/// This is the comptime struct provided through `MetaOptions.field_descriptions`,
/// or an empty struct when no field-level documentation was declared.
pub inline fn attributeDescriptionsOf(comptime T: type) @TypeOf(getMeta(T).AttributeDescriptions) {
    return comptime getMeta(T).AttributeDescriptions;
}

/// Returns the variant descriptions attached to a tagged union type `T`.
///
/// This is the comptime struct provided through `MetaOptions.variants`,
/// or an empty struct when no variant-level documentation was declared.
pub inline fn variantDescriptionsOf(comptime T: type) @TypeOf(getMeta(T).VariantDescriptions) {
    return comptime getMeta(T).VariantDescriptions;
}

test {
    std.testing.refAllDecls(@This());
}
