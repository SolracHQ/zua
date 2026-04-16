//! Metadata for a Zig type that is translated to Lua.
//!
//! This module centralizes translation strategy, custom encode/decode hooks,
//! and method metadata so translation code does not need to replicate fallbacks.
//! `getMeta(T)` is the single entry point for retrieving metadata for a type.

const std = @import("std");
const Mapper = @import("mapper/mapper.zig");
const Primitive = Mapper.Decoder.Primitive;
const Context = @import("state/context.zig");

/// The translation strategy for a type determines how it is represented in Lua and what operations are supported on it. The strategy is the core piece of metadata
pub const Strategy = enum {
    /// The value is represented as a Lua table.
    table,

    /// The value is represented as userdata with a metatable.
    object,

    /// The value is represented as light userdata.
    ptr,

    /// The value is stored as upvalue 1 of a Lua C closure.
    /// Used only in conjunction with `ZuaFn.newClosure`. The struct is
    /// allocated as userdata inside the closure and injected as a `*T`
    /// parameter into the callback. Encode/decode hooks are not supported.
    capture,
};

/// Internal alias for a custom encode hook signature.
///
/// This helper is used by `MetaData` to represent encode hooks that take the
/// current call `Context` and a Zig value of type `T`, then return a proxy type
/// to push into Lua.
pub fn EncodeHook(comptime T: type, comptime ProxyType: type) type {
    return fn (*Context, T) ProxyType;
}

/// Internal alias for a custom decode hook signature.
///
/// This helper represents a hook that receives a Lua `Primitive` and the
/// current evaluation `Context`, then returns a decoded `T` or fails.
pub fn DecodeHook(comptime T: type) type {
    return fn (*Context, Primitive) anyerror!T;
}

/// Internal metadata type used by `ZUA_META` builders.
///
/// `MetaData` stores the translation strategy, any exposed methods, and
/// optional encode/decode hooks for `T`. It is the underlying type behind
/// `Object()`, `Table()`, `Ptr()`, and `strEnum()`.
fn MetaData(
    comptime T: type,
    comptime strat: Strategy,
    comptime methods: anytype,
    comptime ProxyType: type,
) type {
    return struct {
        strategy: Strategy = strat,
        methods: @TypeOf(methods) = methods,
        encode_hook: ?EncodeHook(T, ProxyType) = null,
        decode_hook: ?DecodeHook(T) = null,

        /// Attach a custom encode hook.
        ///
        /// The hook converts `T` into `ProxyType` before the value is pushed to Lua.
        pub fn withEncode(
            self: @This(),
            comptime NewProxyType: type,
            comptime handler: EncodeHook(T, NewProxyType),
        ) MetaData(T, strat, methods, NewProxyType) {
            if (comptime strat == .capture)
                @compileError("capture strategy types do not support encode hooks");

            assertEncodeReturnDiffers(T, NewProxyType);
            return .{
                .strategy = self.strategy,
                .methods = self.methods,
                .encode_hook = handler,
                .decode_hook = self.decode_hook,
            };
        }

        /// Attach a custom decode hook.
        ///
        /// The hook converts a Lua primitive into `T`.
        pub fn withDecode(
            self: @This(),
            comptime handler: DecodeHook(T),
        ) MetaData(T, strat, methods, ProxyType) {
            if (comptime strat == .capture)
                @compileError("capture strategy types do not support decode hooks");

            return .{
                .strategy = self.strategy,
                .methods = self.methods,
                .encode_hook = self.encode_hook,
                .decode_hook = handler,
            };
        }
    };
}

/// Declare `T` as an `.object` translation strategy.
///
/// Object strategy types are represented as full userdata in Lua and
/// expose methods through a metatable. Use this for Zig values that need
/// identity, mutability, and controlled behavior from Lua.
pub fn Object(comptime T: type, comptime methods: anytype) MetaData(T, .object, methods, void) {
    assertStructEnumOrUnion(T);
    return .{ .methods = methods };
}

/// Declare `T` as a `.table` translation strategy.
///
/// Table strategy types are represented as Lua tables with fields mapped from
/// Zig struct members or union variants. This is the default strategy.
pub fn Table(comptime T: type, comptime methods: anytype) MetaData(T, .table, methods, void) {
    assertStructEnumOrUnion(T);
    assertTaggedIfUnion(T);
    return .{ .methods = methods };
}

/// Declare `T` as a `.ptr` translation strategy.
///
/// Pointer strategy types are represented as Lua light userdata, with no
/// metatable or field access. Use this for opaque handles that Lua should
/// not inspect or mutate.
pub fn Ptr(comptime T: type) MetaData(T, .ptr, .{}, void) {
    assertStructEnumOrUnion(T);
    return .{};
}

/// Declare `T` as a `.capture` translation strategy.
///
/// Capture strategy types are stored as userdata in upvalue 1 of a Lua
/// C closure created by `ZuaFn.newClosure`. The struct is allocated once when
/// the closure is pushed and a `*T` pointer is injected into every call through
/// the capture parameter.
///
/// Methods are supported and follow the same rules as `.object`. Use `__gc` to
/// release any owned resources when Lua collects the closure. Encode and decode
/// hooks are not allowed on capture strategy types.
///
/// Arguments:
/// - T: The struct type to use as the closure's captured state.
/// - methods: A comptime struct of method name–function pairs.
///
/// Returns:
/// - MetaData: The metadata value to assign to `pub const ZUA_META`.
///
/// Example:
/// ```zig
/// const CounterState = struct {
///     pub const ZUA_META = zua.Meta.Capture(@This(), .{
///         .__gc = cleanup,
///     });
///     count: i32,
///     step: i32,
///
///     fn cleanup(self: *CounterState) void {
///         _ = self; // release owned resources here
///     }
/// };
/// ```
pub fn Capture(comptime T: type, comptime methods: anytype) MetaData(T, .capture, methods, void) {
    assertStructEnumOrUnion(T);
    return .{ .methods = methods };
}

/// Declare `T` as a string-backed enum with automatic string conversion.
///
/// This sets up `T` as a `.table` type and derives encode/decode hooks so the
/// enum is pushed as a string and parsed from string values.
pub fn strEnum(comptime T: type, comptime methods: anytype) MetaData(T, .table, methods, []const u8) {
    if (@typeInfo(T) != .@"enum")
        @compileError("strEnum requires an enum type, got " ++ @typeName(T));
    return .{
        .strategy = .table,
        .methods = methods,
        .encode_hook = strEnumEncode(T),
        .decode_hook = strEnumDecode(T),
    };
}

/// Returns the compile-time metadata type for `T`.
///
/// This helper is used internally to determine the metadata layout for a
/// type before constructing a metadata instance. It applies the same default
/// rules as `getMeta(T)` but returns a type rather than a value.
///
/// Internally this is used by code that needs to compute metadata shape at
/// compile time without depending on a concrete metadata value.
pub fn getMetaType(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .@"fn") @compileError("function types are not supported by getMeta");
    if (@hasDecl(T, "ZUA_META")) return @TypeOf(T.ZUA_META);
    if (@hasDecl(T, "ZUA_TRANSLATION_STRATEGY")) return @TypeOf(T.ZUA_TRANSLATION_STRATEGY);
    if (info == .@"union" and info.@"union".tag_type == null) return MetaData(T, .object, .{}, void);
    return MetaData(T, .table, .{}, void);
}

/// Returns the metadata value for `T`, applying default strategy rules.
///
/// This is the primary metadata lookup entry point used by translation and
/// type dispatch code. It returns `T.ZUA_META` when present, falls back to
/// `T.ZUA_TRANSLATION_STRATEGY` when declared, and otherwise constructs a
/// default metadata value based on `T`'s shape.
///
/// For plain structs and enums this defaults to `.table`. Untagged unions
/// default to `.object` because they cannot be represented as table variants.
///
/// Example:
/// ```zig
/// const meta = getMeta(MyType);
/// const strategy = meta.strategy;
/// ```
pub fn getMeta(comptime T: type) getMetaType(T) {
    const info = @typeInfo(T);
    if (info == .@"fn") @compileError("function types are not supported by getMeta");
    if (@hasDecl(T, "ZUA_META")) return T.ZUA_META;
    if (@hasDecl(T, "ZUA_TRANSLATION_STRATEGY")) return T.ZUA_TRANSLATION_STRATEGY;
    if (info == .@"union" and info.@"union".tag_type == null) return MetaData(T, .object, .{}, void){};
    return MetaData(T, .table, .{}, void){};
}

fn assertStructEnumOrUnion(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => {},
        else => @compileError(@typeName(T) ++ " must be a struct, enum, or union"),
    }
}

fn assertTaggedIfUnion(comptime T: type) void {
    if (@typeInfo(T) == .@"union") {
        if (@typeInfo(T).@"union".tag_type == null) {
            @compileError(@typeName(T) ++ " is an untagged union, use meta.Object or meta.Ptr instead");
        }
    }
}

fn assertEncodeReturnDiffers(comptime T: type, comptime R: type) void {
    if (T == R)
        @compileError("encode hook return type must differ from " ++ @typeName(T) ++ " to prevent infinite recursion");
}

fn strEnumEncode(comptime T: type) fn (*Context, T) []const u8 {
    return struct {
        fn encode(_: *Context, value: T) []const u8 {
            return @tagName(value);
        }
    }.encode;
}

fn strEnumDecode(comptime T: type) fn (*Context, Primitive) anyerror!T {
    return struct {
        fn decode(ctx: *Context, primitive: Primitive) anyerror!T {
            const str = switch (primitive) {
                .string => |s| s,
                else => return ctx.failTyped(T, "expected string"),
            };
            inline for (std.meta.fields(T)) |field| {
                if (std.mem.eql(u8, str, field.name)) return @field(T, field.name);
            }
            return ctx.failTyped(T, "invalid enum value");
        }
    }.decode;
}
