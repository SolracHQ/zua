const std = @import("std");
const translation = @import("translation.zig");
const lua = @import("../lua/lua.zig");
const Zua = @import("zua.zig").Zua;

/// Translation strategy used by the translation system.
pub const Strategy = enum {
    /// The value is represented as a Lua table, with fields for each struct member or enum variant.
    table,

    /// The value is represented as a full userdata with a metatable, and its members are accessed through metamethods.
    object,

    /// The value is represented as a light userdata pointer to Zig-managed memory. No metatable or metamethods are used.
    zig_ptr,
};

fn assertStructOrEnum(comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"enum" => {},
        else => @compileError(@typeName(T) ++ " must be a struct or enum"),
    }
}

fn assertEncodeReturnDiffers(comptime T: type, comptime R: type) void {
    if (T == R)
        @compileError("encode hook return type must differ from " ++ @typeName(T) ++ " to prevent infinite recursion");
}

fn strEnumEncode(comptime T: type) fn (T) []const u8 {
    return struct {
        fn encode(value: T) []const u8 {
            return @tagName(value);
        }
    }.encode;
}

fn strEnumDecode(comptime T: type) fn (*Zua, lua.StackIndex, lua.Type) anyerror!T {
    return struct {
        fn decode(z: *Zua, index: lua.StackIndex, kind: lua.Type) anyerror!T {
            if (kind != .string) return error.InvalidType;
            const str = lua.toString(z.state, index) orelse return error.InvalidType;
            inline for (std.meta.fields(T)) |field| {
                if (std.mem.eql(u8, str, field.name)) return @field(T, field.name);
            }
            return error.InvalidType;
        }
    }.decode;
}

fn MetaValue(
    comptime T: type,
    comptime strat: Strategy,
    comptime methods: anytype,
    comptime EncodeHook: type,
    comptime DecodeHook: type,
) type {
    return struct {
        strategy: Strategy = strat,
        methods: @TypeOf(methods) = methods,
        encode_hook: EncodeHook = undefined,
        decode_hook: DecodeHook = undefined,

        /// Attaches a custom encode hook to this metadata builder.
        /// The hook converts values of type `T` to another type before they are pushed to Lua.
        pub fn withEncode(
            self: @This(),
            comptime R: type,
            comptime handler: fn (T) R,
        ) MetaValue(T, strat, methods, fn (T) R, DecodeHook) {
            assertEncodeReturnDiffers(T, R);
            return .{
                .strategy = self.strategy,
                .methods = self.methods,
                .encode_hook = handler,
                .decode_hook = self.decode_hook,
            };
        }

        /// Attaches a custom decode hook to this metadata builder.
        /// The hook converts a Lua value on the stack into `T` using the Lua type and index.
        pub fn withDecode(
            self: @This(),
            comptime handler: fn (*Zua, lua.StackIndex, lua.Type) anyerror!T,
        ) MetaValue(T, strat, methods, EncodeHook, fn (*Zua, lua.StackIndex, lua.Type) anyerror!T) {
            return .{
                .strategy = self.strategy,
                .methods = self.methods,
                .encode_hook = self.encode_hook,
                .decode_hook = handler,
            };
        }
    };
}

/// Declares `T` as an object strategy type with userdata and metatable methods.
pub fn Object(comptime T: type, comptime methods: anytype) MetaValue(T, .object, methods, void, void) {
    assertStructOrEnum(T);
    return .{ .methods = methods };
}

/// Declares `T` as a table strategy type with Lua table representation and optional methods.
pub fn Table(comptime T: type, comptime methods: anytype) MetaValue(T, .table, methods, void, void) {
    assertStructOrEnum(T);
    return .{ .methods = methods };
}

/// Declares `T` as an opaque pointer strategy type represented as Lua light userdata.
pub fn Ptr(comptime T: type) MetaValue(T, .zig_ptr, .{}, void, void) {
    assertStructOrEnum(T);
    return .{};
}

/// Declares `T` as a string-backed enum with table strategy and automatic string conversion.
pub fn strEnum(comptime T: type, comptime methods: anytype) MetaValue(T, .table, methods, fn (T) []const u8, fn (*Zua, lua.StackIndex, lua.Type) anyerror!T) {
    if (@typeInfo(T) != .@"enum")
        @compileError("strEnum requires an enum type, got " ++ @typeName(T));
    return .{
        .strategy = .table,
        .methods = methods,
        .encode_hook = strEnumEncode(T),
        .decode_hook = strEnumDecode(T),
    };
}

// Helpers for translation.zig

/// Returns the translation strategy for `T`, defaulting to `.table` when no metadata is declared.
pub fn strategyOf(comptime T: type) Strategy {
    if (@hasDecl(T, "ZUA_META")) return T.ZUA_META.strategy;
    return .table;
}

/// Returns true when `T` declares a custom encode hook via `ZUA_META`.
pub fn hasEncodeHook(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct" and info != .@"enum") return false;
    if (@hasDecl(T, "ZUA_META")) return @TypeOf(T.ZUA_META.encode_hook) != void;
    return false;
}

/// Returns true when `T` declares a custom decode hook via `ZUA_META`.
pub fn hasDecodeHook(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct" and info != .@"enum") return false;
    if (@hasDecl(T, "ZUA_META")) return @TypeOf(T.ZUA_META.decode_hook) != void;
    return false;
}

/// Returns the declared methods table for `T`, or null when no metadata is present.
pub fn methodsOf(comptime T: type) blk: {
    if (@hasDecl(T, "ZUA_META")) {
        break :blk ?@TypeOf(T.ZUA_META.methods);
    } else {
        break :blk ?void;
    }
} {
    if (comptime @hasDecl(T, "ZUA_META")) {
        return T.ZUA_META.methods;
    }
    return null;
}
