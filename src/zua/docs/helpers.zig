//! Doc-specific helper and query functions.
//!
//! This module provides comptime introspection helpers used by the collection
//! phase to normalize types, extract metadata, and build display strings for
//! Lua annotations. It re-exports several helpers from `meta/helpers.zig`.

const std = @import("std");
const Docs = @import("./docs.zig");
const emit = @import("emit.zig");
const types = @import("types.zig");
const DisplayContext = types.DisplayContext;
const Context = @import("../state/context.zig");
const Native = @import("../functions/native.zig");
const Handlers = @import("../handlers/handlers.zig");
const RawFunction = @import("../handlers/function.zig").Function;
const RawTable = @import("../handlers/table.zig").Table;
const RawUserdata = @import("../handlers/userdata.zig").Userdata;
const Mapper = @import("../mapper/mapper.zig");
const Meta = @import("../meta/meta.zig");
pub const isNativeWrapperType = @import("../meta/helpers.zig").isNativeWrapperType;
pub const hasStructDecl = @import("../meta/helpers.zig").hasStructDecl;
pub const isCapturePointer = @import("../meta/helpers.zig").isCapturePointer;
pub const typeListCount = @import("../meta/helpers.zig").typeListCount;
pub const typeListAt = @import("../meta/helpers.zig").typeListAt;

/// Produces a human-readable Lua type string for a Zig type.
///
/// Handles optionals (`?T` -> `T?`), string types (`string`), primitive
/// mappings (`bool` -> `boolean`, `i32` -> `integer`, `f64` -> `number`),
/// arrays and slices (`T[]`), pointer-to-struct (uses `Meta.nameOf`),
/// typed function handles (`fun(...)`), and user-defined types (uses
/// `Meta.nameOf`).
///
/// Arguments:
/// - self: The docs generator (for arena allocation).
/// - T: The Zig type to render.
/// - ctx: The display context controlling formatting.
///
/// Returns:
/// - []const u8: Arena-allocated Lua type name string.
pub fn displayTypeName(self: *Docs, comptime T: type, comptime ctx: DisplayContext) ![]const u8 {
    if (comptime Mapper.isOptional(T)) {
        const child_name = try displayTypeName(self, Mapper.optionalChild(T), ctx);
        return std.fmt.allocPrint(self.arena.allocator(), "{s}?", .{child_name});
    }

    const Normalized = normalizeReferencedType(T);

    if (comptime isTransparentTypedWrapper(Normalized)) {
        return displayTypeName(self, unwrapTransparentTypedWrapper(Normalized), ctx);
    }

    if (comptime isTypedFunctionHandle(Normalized)) {
        return functionHandleSignature(self, Normalized);
    }

    if (Normalized == RawTable) return persist(self, "table");
    if (Normalized == RawFunction) return persist(self, "function");
    if (Normalized == RawUserdata) return persist(self, "userdata");
    if (Normalized == Mapper.Decoder.VarArgs) return persist(self, "any");

    if (comptime @typeInfo(Normalized) == .@"fn") return persist(self, "function");
    if (comptime isNativeWrapperType(Normalized)) return persist(self, "function");
    if (comptime Mapper.isStringValueType(Normalized)) return persist(self, "string");

    return switch (@typeInfo(Normalized)) {
        .bool => persist(self, "boolean"),
        .int, .comptime_int => persist(self, "integer"),
        .float, .comptime_float => persist(self, "number"),
        .void => persist(self, "nil"),
        .optional => |optional| displayTypeName(self, optional.child, ctx),
        .array => |array| blk: {
            const child_name = try displayTypeName(self, array.child, ctx);
            break :blk try std.fmt.allocPrint(self.arena.allocator(), "{s}[]", .{child_name});
        },
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                const child_name = try displayTypeName(self, ptr.child, ctx);
                break :blk try std.fmt.allocPrint(self.arena.allocator(), "{s}[]", .{child_name});
            }

            if (ptr.size == .one) {
                const child = ptr.child;
                if (comptime @typeInfo(child) == .@"struct" or @typeInfo(child) == .@"union" or @typeInfo(child) == .@"enum" or @typeInfo(child) == .@"opaque") {
                    break :blk try persist(self, Meta.nameOf(child));
                }
            }

            break :blk try persist(self, @typeName(Normalized));
        },
        .@"struct", .@"union", .@"enum", .@"opaque" => persist(self, Meta.nameOf(Normalized)),
        else => persist(self, @typeName(Normalized)),
    };
}

/// Renders the signature of a typed function handle (`Args` + `Result` struct)
/// as a Lua `fun(...) : ...` string.
///
/// Arguments:
/// - self: The docs generator (for arena allocation).
/// - T: The typed function handle type (must have `Args` and `Result` struct
///   declarations).
///
/// Returns:
/// - []const u8: Arena-allocated Lua function signature string.
pub fn functionHandleSignature(self: *Docs, comptime T: type) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.arena.allocator(), "fun(");

    if (comptime @typeInfo(T.Args) == .@"struct") {
        inline for (@typeInfo(T.Args).@"struct".fields, 0..) |field, index| {
            if (index > 0) try out.appendSlice(self.arena.allocator(), ", ");
            const arg_name = try std.fmt.allocPrint(self.arena.allocator(), "arg{d}", .{index + 1});
            const arg_type_str = try displayTypeName(self, field.type, .parameter);
            try emit.appendFmt(self.arena.allocator(), &out, "{s}: {s}", .{ arg_name, arg_type_str });
        }
    }

    try out.appendSlice(self.arena.allocator(), ")");

    if (comptime @typeInfo(T.Result) == .@"struct") {
        try out.appendSlice(self.arena.allocator(), ": ");
        inline for (@typeInfo(T.Result).@"struct".fields, 0..) |field, index| {
            if (index > 0) try out.appendSlice(self.arena.allocator(), ", ");
            try out.appendSlice(self.arena.allocator(), try displayTypeName(self, field.type, .return_value));
        }
    }

    return out.toOwnedSlice(self.arena.allocator());
}

/// Inserts a placeholder doc into the cache if the key is not already present.
///
/// Returns `true` if the placeholder was inserted (caller should proceed with
/// full collection), or `false` if the entry already exists (caller should
/// skip).
///
/// Arguments:
/// - self: The docs generator.
/// - key: The cache key (typically `@typeName` or a function name).
/// - display_name: The Lua display name for the placeholder.
/// - description: The description text for the placeholder.
///
/// Returns:
/// - bool: `true` if the placeholder was newly inserted.
pub fn insertPlaceholderIfNeeded(self: *Docs, key: []const u8, display_name: []const u8, description: []const u8) !bool {
    if (self.cache.get(key) != null) return false;

    try self.cache.put(try persist(self, key), .{ .PlaceHolder = .{
        .name = try persist(self, display_name),
        .description = try persist(self, description),
    } });
    return true;
}

/// Duplicates `text` into the generator's arena.
///
/// This is the primary persistence mechanism: all doc strings live in the
/// arena and are freed together in `deinit`.
///
/// Arguments:
/// - self: The docs generator (provides the arena).
/// - text: The string to persist.
///
/// Returns:
/// - []const u8: Arena-allocated copy of `text`.
pub fn persist(self: *Docs, text: []const u8) ![]const u8 {
    return self.arena.allocator().dupe(u8, text);
}

/// Wraps a method value, converting a plain Zig function to a `Native` wrapper
/// if necessary.
///
/// Accepts either a `NativeFn`/`Closure` wrapper (returned as-is) or a plain
/// Zig function (wrapped via `Native.new`).
///
/// Arguments:
/// - method_value: A Zig function or native wrapper value representing a method.
///
/// Returns:
/// - A `NativeFn` or `Closure` wrapper.
pub fn wrapMethod(comptime method_value: anytype) @TypeOf(if (@typeInfo(@TypeOf(method_value)) == .@"fn") Native.new(method_value, .{}, .{}) else method_value) {
    const T = @TypeOf(method_value);
    if (comptime @typeInfo(T) == .@"fn") return Native.new(method_value, .{}, .{});
    if (comptime isNativeWrapperType(T)) return method_value;
    @compileError("method docs only support Zig functions or NativeFn/Closure wrappers");
}

/// Normalizes a top-level type by unwrapping any transparent typed wrappers.
///
/// Arguments:
/// - T: The type to normalize.
///
/// Returns:
/// - type: The underlying type, with any transparent wrapper removed.
pub fn normalizeRootType(comptime T: type) type {
    if (comptime isTransparentTypedWrapper(T)) return unwrapTransparentTypedWrapper(T);
    return T;
}

/// Determines whether a type should be emitted as an `---@alias` instead of a
/// `---@class`.
///
/// Returns `true` for tagged unions (discriminated unions with an explicit
/// tag) and for enums whose proxy type is `[]const u8`.
///
/// Arguments:
/// - T: The Zig type to check.
///
/// Returns:
/// - bool: `true` if the type should be emitted as an alias.
pub fn shouldEmitAlias(comptime T: type) bool {
    if (Meta.strategyOf(T) != .table) return false;
    return switch (@typeInfo(T)) {
        .@"union" => |info| info.tag_type != null,
        .@"enum" => Meta.proxyTypeOf(T) == []const u8,
        else => false,
    };
}

/// Normalizes a type for reference comparison by unwrapping optionals,
/// transparent wrappers, and single-element pointers to named types.
///
/// Arguments:
/// - T: The type to normalize.
///
/// Returns:
/// - type: The innermost relevant type.
pub fn normalizeReferencedType(comptime T: type) type {
    if (comptime Mapper.isOptional(T)) return normalizeReferencedType(Mapper.optionalChild(T));
    if (comptime isTransparentTypedWrapper(T)) return unwrapTransparentTypedWrapper(T);

    return switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .one)
            switch (@typeInfo(ptr.child)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => ptr.child,
                else => T,
            }
        else
            T,
        else => T,
    };
}

/// Unwraps transparent typed wrappers (`__ZUA_USERDATA_TYPE` or
/// `__ZUA_TABLE_VIEW`) to reveal the underlying Zua type.
///
/// Arguments:
/// - T: The wrapper type.
///
/// Returns:
/// - type: The underlying Zua type.
pub fn unwrapTransparentTypedWrapper(comptime T: type) type {
    if (comptime hasStructDecl(T, "__ZUA_USERDATA_TYPE")) return T.__ZUA_USERDATA_TYPE;
    if (comptime hasStructDecl(T, "__ZUA_TABLE_VIEW")) return @typeInfo(@TypeOf(@as(T, undefined).ref)).pointer.child;
    return T;
}

/// Returns `true` if `T` is a transparent typed wrapper (userdata or table
/// view).
///
/// Arguments:
/// - T: The type to check.
///
/// Returns:
/// - bool: `true` if the type has `__ZUA_USERDATA_TYPE` or `__ZUA_TABLE_VIEW`.
pub fn isTransparentTypedWrapper(comptime T: type) bool {
    return hasStructDecl(T, "__ZUA_USERDATA_TYPE") or hasStructDecl(T, "__ZUA_TABLE_VIEW");
}

/// Returns `true` if `T` is a typed function handle (has `Args`, `Result`, and
/// `function` fields).
///
/// Arguments:
/// - T: The type to check.
///
/// Returns:
/// - bool: `true` if `T` is a typed function handle.
pub fn isTypedFunctionHandle(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Args") and @hasDecl(T, "Result") and @hasField(T, "function");
}

/// Returns `true` if `T` is a type that should be skipped during doc
/// collection.
///
/// Ignored types are: `*Context`, `Context`, `Mapper.Decoder.Primitive`, and
/// `Handlers.Handle`.
///
/// Arguments:
/// - T: The type to check.
///
/// Returns:
/// - bool: `true` if the type should be ignored.
pub fn isIgnoredDocType(comptime T: type) bool {
    return T == *Context or T == Context or T == Mapper.Decoder.Primitive or T == Handlers.Handle;
}

/// Looks up a field description from a `ZUA_META` attribute descriptions
/// struct.
///
/// Arguments:
/// - descriptions: The `ZUA_META` attribute description struct.
/// - field_name: The field name to look up.
///
/// Returns:
/// - []const u8: The description string, or `""` if not found.
pub fn fieldDescription(comptime descriptions: anytype, comptime field_name: []const u8) []const u8 {
    inline for (@typeInfo(@TypeOf(descriptions)).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, field_name)) {
            const val = @field(descriptions, field.name);
            return if (val) |s| s else "";
        }
    }
    return "";
}

/// Looks up parameter documentation from a `Native` wrapper's `ArgInfo` array.
///
/// Arguments:
/// - args: The wrapper's `ArgInfo` slice.
/// - index: The parameter index.
///
/// Returns:
/// - struct: A struct with `name` and `description` fields. Falls back to
///   `"arg{N}"` and `""` when the index is out of range.
pub fn argDocInfo(args: []const Native.ArgInfo, comptime index: usize) struct { name: []const u8, description: []const u8 } {
    if (index < args.len) {
        return .{
            .name = args[index].name,
            .description = args[index].description orelse "",
        };
    }

    return .{
        .name = std.fmt.comptimePrint("arg{d}", .{index + 1}),
        .description = "",
    };
}

/// Checks whether a parameter type is the method's self type.
///
/// Matches exact equality, `RawTable`/`RawUserdata`, transparent wrappers
/// pointing to the owner type, and single-element pointers to the owner type.
///
/// Arguments:
/// - ParamType: The parameter type to check.
/// - OwnerType: The expected owner type.
///
/// Returns:
/// - bool: `true` if `ParamType` represents `self`.
pub fn isSelfParam(comptime ParamType: type, comptime OwnerType: type) bool {
    if (ParamType == OwnerType) return true;
    if (ParamType == RawTable or ParamType == RawUserdata) return true;
    if (comptime isTransparentTypedWrapper(ParamType)) return unwrapTransparentTypedWrapper(ParamType) == OwnerType;

    if (@typeInfo(ParamType) == .pointer and @typeInfo(ParamType).pointer.size == .one) {
        return @typeInfo(ParamType).pointer.child == OwnerType;
    }

    return false;
}
