//! Compile-time metadata builder for `ZUA_SHAPE` declarations. Produces
//! the struct type that carries a type's translation strategy, hooks,
//! methods, and documentation fields. The encoder, decoder, and docs
//! generator query this metadata through `getMeta` and `strategyOf`.

const std = @import("std");
const builtin = @import("builtin");

const EncodeHookType = @import("./helpers.zig").EncodeHookType;
const DecodeHookType = @import("./helpers.zig").DecodeHookType;
const DocsHookType = @import("./helpers.zig").DocsHookType;
const Mapper = @import("../mapper/api.zig");
const Primitive = Mapper.Primitive;
const Context = @import("../context.zig");
const Assertions = @import("./assertions.zig");
const Marker = @import("../marker.zig");
const Trampoline = @import("./trampoline.zig");

pub const MappingStrategy = enum {
    table,
    object,
    ptr,
    closure,
};

pub fn VariantInfoType(comptime FieldType: type) type {
    const fd_type = FieldDescriptions(FieldType);
    return struct {
        name: ?[]const u8 = null,
        description: ?[]const u8 = null,
        field_descriptions: fd_type = .{},
    };
}

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

/// Constructs the compile-time metadata type for `ZUA_SHAPE`.
///
/// This is the low-level builder that all shape helpers (`Object`, `Table`,
/// `Ptr`, `Closure`) delegate to. It produces a struct type with the constants
/// that translation, documentation, and stub-generation code query at compile
/// time.
///
/// Most types should use the shape helpers in `zua.Shape` instead of calling
/// `MetaData` directly. Use `MetaData` directly only when you need to customize
/// the proxy type, encode hook, or decode hook in ways the helpers do not
/// expose.
///
/// The returned type has these public members:
/// - `Strategy`: the `MappingStrategy` for translation.
/// - `Proxy`: the proxy type used by encode hooks.
/// - `Methods`: the method table exposed to Lua.
/// - `EncodeHook`: a hook converting `T` to `ProxyType`, or a no-op default.
/// - `DecodeHook`: a hook converting a Lua primitive to `T`, or a no-op default.
/// - `Name`: the documentation name (explicit or `@typeName`).
/// - `Description`: the documentation description string.
/// - `AttributeDescriptions`: per-field documentation.
/// - `VariantDescriptions`: per-variant documentation for tagged unions.
///
/// Arguments:
/// - Type: The original Zig type the metadata describes.
/// - ProxyType: The type used as an intermediate representation during encode.
///   Most strategies use `void`; `StrEnum` uses `[]const u8`.
/// - strategy: The mapping strategy (table, object, ptr, closure).
/// - encode_hook: Optional encode hook. `null` produces a no-op default.
/// - decode_hook: Optional decode hook. `null` produces a no-op default.
/// - methods: A comptime struct of method name–function pairs, or `null`/`{}`.
/// - options: A `MetaOptions` struct with optional `name`, `description`,
///   `field_descriptions`, and `variants`.
///
/// Returns:
/// - `type`: A struct type suitable for use as `pub const ZUA_SHAPE`.
///
/// Example:
/// ```zig
/// pub const ZUA_SHAPE = MetaData(MyType, []const u8, .table,
///     MyType.encode, MyType.decode,
///     .{ .__gc = cleanup },
///     .{ .name = "MyType", .description = "Does a thing." },
/// );
/// ```
pub fn MetaData(
    comptime Type: type,
    comptime ProxyType: type,
    comptime strategy: MappingStrategy,
    comptime encode_hook: ?EncodeHookType(Type, ProxyType),
    comptime decode_hook: ?DecodeHookType(Type),
    comptime methods: anytype,
    comptime options: anytype,
    comptime docs_hook: ?DocsHookType(Type),
) type {
    if (comptime !@hasDecl(Type, "ZUA_SHAPE") and !Marker.isDefaultGuard(Type)) {
        @compileError(@typeName(Type) ++ " has no visible ZUA_SHAPE: is it misspelled or declared outside the type?");
    }

    const T = if (@hasDecl(Type, "__ZUA_DEFAULT_GUARD_ORIGINAL_TYPE")) Type.__ZUA_DEFAULT_GUARD_ORIGINAL_TYPE else Type;

    const opts_name = if (@hasField(@TypeOf(options), "name")) options.name else null;
    const opts_description = if (@hasField(@TypeOf(options), "description")) options.description else null;
    const opts_field_descriptions = if (@hasField(@TypeOf(options), "field_descriptions")) options.field_descriptions else .{};
    const opts_variants = if (@hasField(@TypeOf(options), "variants")) options.variants else .{};

    return struct {
        pub const Strategy = strategy;
        pub const Proxy = ProxyType;
        pub const Methods = if (@typeInfo(@TypeOf(methods)) != .@"struct") .{} else methods;
        pub const EncodeHook: EncodeHookType(T, ProxyType) = encode_hook orelse default_encode;
        pub const DecodeHook: DecodeHookType(T) = decode_hook orelse default_decode;
        pub const Description: []const u8 = opts_description orelse "";
        pub const Name: []const u8 = opts_name orelse blk: {
            const full: []const u8 = @typeName(T);
            const dot = std.mem.lastIndexOfScalar(u8, full, '.');
            break :blk if (dot) |d| full[d + 1 ..] else full;
        };
        pub const AttributeDescriptions = if (@typeInfo(@TypeOf(opts_field_descriptions)) != .@"struct") .{} else opts_field_descriptions;
        pub const VariantDescriptions = if (@typeInfo(@TypeOf(opts_variants)) != .@"struct") .{} else opts_variants;
        pub const DocsHook: ?DocsHookType(T) = docs_hook;

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
            comptime handler: EncodeHookType(T, NewProxyType),
        ) type {
            if (comptime strategy == .closure)
                @compileError("closure strategy type " ++ @typeName(T) ++ " does not support encode hook");
            return comptime MetaData(T, NewProxyType, strategy, handler, decode_hook, methods, options, null);
        }

        /// Attach a custom decode hook.
        ///
        /// The hook converts a Lua primitive into `T`.
        pub inline fn withDecode(
            comptime handler: DecodeHookType(T),
        ) type {
            if (comptime strategy == .closure)
                @compileError("closure strategy type " ++ @typeName(T) ++ " does not support decode hook");

            return comptime MetaData(T, ProxyType, strategy, encode_hook, handler, methods, options, null);
        }

        /// Attach a custom docs hook that generates a complete `Doc` entry,
        /// bypassing the default field/method/alias collection.
        ///
        /// The hook receives the `*Docs` generator and returns a fully
        /// populated `Doc` (Alias, Table, Object, etc.) that replaces the
        /// auto-collected entry.
        pub inline fn withDocs(
            comptime handler: DocsHookType(T),
        ) type {
            if (comptime strategy == .closure)
                @compileError("closure strategy type " ++ @typeName(T) ++ " does not support docs hook");

            return comptime MetaData(T, ProxyType, strategy, encode_hook, decode_hook, methods, options, handler);
        }
    };
}

/// Wraps a type so that `MetaData` can distinguish default metadata from
/// user-declared `ZUA_SHAPE`.
///
/// When `getMeta` falls back to the default strategy (`.table` for structs,
/// `.object` for untagged unions) it wraps the original type in `DefaultGuard`.
/// The guard's `__ZUA_DEFAULT_GUARD_ORIGINAL_TYPE` field lets internal code recover
/// the original type while `MetaData`'s compile-time guard (`@hasDecl(Type,
/// "ZUA_SHAPE")`) correctly identifies these as having no explicit metadata.
///
/// Arguments:
/// - T: The original type to wrap.
///
/// Returns:
/// - type: A struct type with a single `__ZUA_DEFAULT_GUARD_ORIGINAL_TYPE` constant.
pub fn DefaultGuard(comptime T: type) type {
    return struct {
        pub const __ZUA_MARKER = Marker.Marker.default_guard;
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
pub inline fn getMeta(comptime T: type) type {
    Assertions.assertContainerType(T);
    // Force evaluation of all public declarations in debug builds so
    // misspelled ZUA_SHAPE constants are caught at compile time.
    // Skipped in release to preserve lazy evaluation semantics.
    if (comptime builtin.mode == .Debug) {
        inline for (comptime std.meta.declarations(T)) |decl| {
            _ = &@field(T, decl.name);
        }
    }
    const info = @typeInfo(T);
    if (comptime @hasDecl(T, "ZUA_SHAPE")) return T.ZUA_SHAPE;
    if (comptime info == .@"union" and info.@"union".tag_type == null) return MetaData(DefaultGuard(T), void, .object, null, null, null, .{}, null);
    return MetaData(DefaultGuard(T), void, .table, null, null, null, .{}, null);
}

/// Returns the translation strategy declared for `T`.
///
/// This is the main branch point used by translation and docs code to decide
/// whether `T` behaves as a table, userdata object, light userdata pointer,
/// or closure capture.
pub inline fn strategyOf(comptime T: type) MappingStrategy {
    return comptime getMeta(T).Strategy;
}

/// Returns the method set exposed by `T`.
///
/// The returned comptime struct is the method table declared on `ZUA_SHAPE`,
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
/// For most strategies this is `void`, but helpers such as `StrEnum()` use a
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

/// Builds metadata for a closure-shaped type.
///
/// The struct is stored as the closure's captured state. Each call from
/// Lua invokes `callback` with `*T` as the first parameter (or second
/// if `*Context` comes first). Remaining parameters are decoded from Lua.
pub fn MetaDataForClosure(comptime T: type, comptime callback: anytype, comptime gc: anytype, comptime opts: Trampoline.FnOptions) type {
    Assertions.assertContainerType(T);
    if (comptime @typeInfo(T) != .@"struct")
        @compileError("Closure requires a struct type, got " ++ @typeName(T));

    const gc_methods = if (gc == null or gc == void) .{} else .{ .__gc = gc };
    const trampoline_type = comptime Trampoline.makeClosure(T, callback, .{ .args = opts.args, .description = opts.description });

    return struct {
        pub const Strategy = MappingStrategy.closure;
        pub const Proxy = void;
        pub const EncodeHook: EncodeHookType(T, void) = struct {
            fn hook(_: *Context, _: T) anyerror!?void {
                return null;
            }
        }.hook;
        pub const DecodeHook: DecodeHookType(T) = struct {
            fn hook(_: *Context, _: Primitive) anyerror!?T {
                return null;
            }
        }.hook;
        pub const Methods = gc_methods;
        pub const Description: []const u8 = opts.description;
        pub const Name: []const u8 = blk: {
            const full: []const u8 = @typeName(T);
            const dot = std.mem.lastIndexOfScalar(u8, full, '.');
            break :blk if (dot) |d| full[d + 1 ..] else full;
        };
        pub const AttributeDescriptions = .{};
        pub const VariantDescriptions = .{};
        pub const DocsHook: ?DocsHookType(T) = null;
        pub const __ZUA_CLOSURE_TRAMPOLINE = trampoline_type;
    };
}

/// Returns the trampoline type for a closure type `T`.
/// Returns `null` if `T` is not a `.closure` type.
pub inline fn closureTrampolineType(comptime T: type) ?type {
    if (comptime strategyOf(T) != .closure) return null;
    const meta = comptime getMeta(T);
    return comptime meta.__ZUA_CLOSURE_TRAMPOLINE;
}

test {
    std.testing.refAllDecls(@This());
}
