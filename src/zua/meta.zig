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
///
/// In the case the developer wants to only encode certain values but continue with
/// the default path for others can just return null to indicate the default encoding should be used.
///
/// the optional return also allow use the hook to transform the value returning the same type but with different content,
/// for example to implement a custom string encoding for a struct while still pushing it as a table.
pub fn EncodeHook(comptime T: type, comptime ProxyType: type) type {
    return fn (*Context, T) anyerror!?ProxyType;
}

/// Internal alias for a custom decode hook signature.
///
/// This helper represents a hook that receives a Lua `Primitive` and the
/// current evaluation `Context`, then returns a decoded `T` or fails.
///
/// In the case the developer wants to only decode certain primitives but
/// continue with the default path for others can just return null to indicate the default decoding should be used.
pub fn DecodeHook(comptime T: type) type {
    return fn (*Context, Primitive) anyerror!?T;
}

/// Internal metadata type used by `ZUA_META` builders.
///
/// `MetaData` stores the translation strategy, any exposed methods, and
/// optional encode/decode hooks for `T`. It is the underlying type behind
/// `Object()`, `Table()`, `Ptr()`, and `strEnum()`.
fn MetaData(
    comptime Type: type,
    comptime strat: Strategy,
    comptime methods: anytype,
    comptime ProxyType: type,
) type {
    // Fires only when someone calls Table(..), Object(..), etc. with a type
    // that has no visible ZUA_META. Lazy evaluation means this only runs when
    // getMeta forces evaluation by iterating public declarations, so if it
    // fires the most likely cause is a misspelling or a declaration outside
    // the type body.
    if (comptime !@hasDecl(Type, "ZUA_META") and !@hasDecl(Type, "__DEFAULT_GUARD_ORIGINAL_TYPE")) {
        @compileError(@typeName(Type) ++ " has no visible ZUA_META: is it misspelled or declared outside the type?");
    }

    const T = if (@hasDecl(Type, "__DEFAULT_GUARD_ORIGINAL_TYPE")) Type.__DEFAULT_GUARD_ORIGINAL_TYPE else Type;

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
                @compileError("capture strategy type " ++ @typeName(T) ++ " do not support encode hook");
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
                @compileError("capture strategy type " ++ @typeName(T) ++ " do not support decode hook");

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
///
/// Example:
/// ```zig
/// const Process = struct {
///     pub const ZUA_META = zua.Meta.Object(Process, .{
///         .__gc = cleanup,
///         .__tostring = display,
///         .getParentPid = getParentPid,
///     });
///
///     pid: std.posix.pid_t,
///     name: []const u8,
/// };
/// ```
pub fn Object(comptime T: type, comptime methods: anytype) MetaData(T, .object, methods, void) {
    assertContainerType(T);
    return .{ .methods = methods };
}

/// Declare `T` as a `.table` translation strategy.
///
/// Table strategy types are represented as Lua tables with fields mapped from
/// Zig struct members or union variants. This is the default strategy.
///
/// Example:
/// ```zig
/// const Point = struct {
///     pub const ZUA_META = zua.Meta.Table(Point, .{});
///     x: i32,
///     y: i32,
/// };
/// ```
pub fn Table(comptime T: type, comptime methods: anytype) MetaData(T, .table, methods, void) {
    assertContainerType(T);
    assertTaggedIfUnion(T);
    return .{ .methods = methods };
}

/// Declare `T` as a `.ptr` translation strategy.
///
/// Pointer strategy types are represented as Lua light userdata, with no
/// metatable or field access. Use this for opaque handles that Lua should
/// not inspect or mutate.
pub fn Ptr(comptime T: type) MetaData(T, .ptr, .{}, void) {
    assertContainerType(T);
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
    assertContainerType(T);
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

/// Declare `T` as a list-type `.object` translation strategy.
///
/// This builds a userdata-backed list object that supports Lua indexing,
/// length queries, and iterator semantics. The `getElements` accessor is
/// used to derive element values and implement the generated methods:
/// `get`, `__index`, `__len`, and `iter`.
///
/// User-provided `methods` are merged with the generated list methods, and
/// compile-time collisions are rejected so generated names stay stable.
///
/// `getElements` must be a comptime function taking `*T` and returning a
/// slice of element values.
///
/// Example:
/// ```zig
/// const Process = struct { /* ... */ };
/// const ProcList = struct {
///     pub const ZUA_META = zua.Meta.List(ProcList, getElements, .{
///         .__gc = deinit,
///         .__tostring = display,
///     });
///
///     processes: std.ArrayList(zua.Object(Process)),
/// };
///
/// fn getElements(self: *ProcList) []zua.Object(Process) {
///     return self.processes.items;
/// }
/// ```
pub fn List(comptime T: type, comptime getElements: anytype, comptime methods: anytype) MetaData(T, .object, mergeMethodSets(generateListMethodsSet(T, getElements), methods), void) {
    assertContainerType(T);
    assertNoListCollisions(methods);
    return .{};
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
    assertContainerType(T);
    // Force evaluation of all public declarations in debug builds so
    // misspelled ZUA_META constants are caught at compile time.
    // Skipped in release to preserve lazy evaluation semantics.
    if (comptime @import("builtin").mode == .Debug) {
        inline for (comptime std.meta.declarations(T)) |decl| {
            _ = &@field(T, decl.name);
        }
    }
    const info = @typeInfo(T);
    if (comptime @hasDecl(T, "ZUA_META")) return @TypeOf(T.ZUA_META);
    if (comptime info == .@"union" and info.@"union".tag_type == null) return MetaData(DefaultGuard(T), .object, .{}, void);
    return MetaData(DefaultGuard(T), .table, .{}, void);
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
    assertContainerType(T);
    const info = @typeInfo(T);
    if (comptime @hasDecl(T, "ZUA_META")) return T.ZUA_META;
    if (comptime info == .@"union" and info.@"union".tag_type == null) return MetaData(DefaultGuard(T), .object, .{}, void){};
    return MetaData(DefaultGuard(T), .table, .{}, void){};
}

pub fn DefaultGuard(comptime T: type) type {
    return struct {
        pub const __DEFAULT_GUARD_ORIGINAL_TYPE = T;
    };
}

fn assertTaggedIfUnion(comptime T: type) void {
    if (@typeInfo(T) == .@"union") {
        if (@typeInfo(T).@"union".tag_type == null) {
            @compileError(@typeName(T) ++ " is an untagged union, use meta.Object or meta.Ptr instead");
        }
    }
}

fn assertContainerType(comptime T: type) void {
    const info = @typeInfo(T);
    if (comptime info != .@"struct" and info != .@"union" and info != .@"enum" and info != .@"opaque") {
        @compileError(@typeName(T) ++ " is not a struct, union, enum, or opaque type and cannot be used with meta strategies that require field mapping");
    }
}

fn strEnumEncode(comptime T: type) EncodeHook(T, []const u8) {
    return struct {
        fn encode(_: *Context, value: T) !?[]const u8 {
            return @tagName(value);
        }
    }.encode;
}

fn strEnumDecode(comptime T: type) DecodeHook(T) {
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

/// Derives the element type from a getElements accessor function.
///
/// `getElements` must be a comptime function with an explicit return type
/// of a slice, such as `[]T` or `[]const T`. The returned slice element type
/// becomes the list element type for generated iterator and indexing helpers.
fn ElementType(comptime getElements: anytype) type {
    const R = @typeInfo(@TypeOf(getElements)).@"fn".return_type orelse
        @compileError("getElements must have an explicit return type");
    const info = @typeInfo(R);
    if (info != .pointer or info.pointer.size != .slice)
        @compileError("getElements must return a slice type, got " ++ @typeName(R));
    return info.pointer.child;
}

/// Validates that none of the reserved List method names appear in user methods.
/// Reserved names are those generated by List: get, iter, __index, __len.
fn assertNoListCollisions(comptime methods: anytype) void {
    const reserved = [_][]const u8{ "get", "iter", "__index", "__len" };
    inline for (@typeInfo(@TypeOf(methods)).@"struct".fields) |field| {
        inline for (reserved) |name| {
            if (comptime std.mem.eql(u8, field.name, name))
                @compileError("List already generates '" ++ name ++ "'; remove it from methods or use Object instead");
        }
    }
}

/// Computes a merged struct type for two method sets.
///
/// This is an internal helper used by `List` to create a combined method
/// struct from generated list methods and any user-provided method table.
/// Both input values must be comptime structs, and the resulting type is a
/// new synthetic struct containing all fields from `a` and `b`.
fn mergeMethodType(comptime a: anytype, comptime b: anytype) type {
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

/// Merges two comptime method sets into one struct value.
///
/// The result is a concrete struct value whose fields are copied from `a`
/// followed by `b`. This is used by `List` so generated methods and user
/// methods can coexist on the same metadata value.
///
/// If both sets contain the same method name, the merge is invalid and should
/// be rejected earlier by `assertNoListCollisions`.
fn mergeMethodSets(comptime a: anytype, comptime b: anytype) mergeMethodType(a, b) {
    const R = mergeMethodType(a, b);
    var result: R = undefined;
    const fa = @typeInfo(@TypeOf(a)).@"struct".fields;
    const fb = @typeInfo(@TypeOf(b)).@"struct".fields;
    inline for (fa) |f| @field(result, f.name) = @field(a, f.name);
    inline for (fb) |f| @field(result, f.name) = @field(b, f.name);
    return result;
}

fn generatedListMethods(comptime L: type, comptime getElements: anytype) type {
    const T = ElementType(getElements);
    const Handlers = @import("handlers/handlers.zig");
    const Native = @import("functions/native.zig");

    return struct {
        /// Returns the element at 1-based `index`, or null when out of range.
        pub fn get(self: *L, index: usize) ?T {
            if (index == 0) return null;
            const elems = getElements(self);
            if (index - 1 < elems.len) return elems[index - 1];
            return null;
        }

        /// Lua `__index` metamethod forwarding to `get`.
        pub fn __index(self: *L, index: usize) ?T {
            return get(self, index);
        }

        /// Lua `__len` metamethod returning the element count.
        pub fn __len(self: *L, _: *L) usize {
            return getElements(self).len;
        }

        fn iget(self: *L, index: usize) !struct { ?usize, ?T } {
            const elem = get(self, index);
            const next = if (elem != null) index + 1 else null;
            return .{ next, elem };
        }

        /// Iterator constructor for `for ... in` loops over the list.
        pub fn iter(self: Handlers.Userdata) struct {
            Native.NativeFn(iget, .{}),
            Handlers.Userdata,
            ?usize,
        } {
            return .{ .{}, self, 1 };
        }
    };
}

/// Build the generated method set used by `List`.
///
/// This returns a struct type containing the list helpers `get`, `__index`,
/// `__len`, and `iter`, which can then be merged with user-defined methods.
fn generateListMethodsSet(comptime L: type, comptime getElements: anytype) @TypeOf(.{
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
