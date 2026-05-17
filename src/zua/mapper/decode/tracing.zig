//! Structured path tracing for decode errors.
//!
//! When a decode operation fails, the trace records exactly where the failure
//! happened (which argument, field, or index) and why (wrong type, out of
//! range, etc.). The formatted message looks like
//! `config.metadata.version: expected i32, got string`.
//!
//! Hook implementations receive a `Trace` and can inspect `trace.err.tag`
//! directly instead of parsing error strings. Use `formatDecodePath` to turn
//! the path into a readable string and `DecodeError.format` for the message.

const std = @import("std");
const Internals = @import("../internals.zig");
const ArgInfo = @import("../../shape/trampoline.zig").ArgInfo;
const PrimitiveTag = @import("../api.zig").PrimitiveTag;
const ShapeData = @import("../../shape/shape_data.zig");


/// One step in a decode trace path.
///
/// A path is an array of segments terminated by `empty`. The formatter
/// walks the array until it hits `empty` and joins the segments into a
/// string like `arg0.metadata.version` or `config[3].name`.
///
/// - `arg(n)`: the n-th function parameter.
/// - `field(name)`: a struct or union field accessed by name.
/// - `index(i)`: an array/slice element accessed by integer key.
/// - `empty`: sentinel terminator; not included in formatted output.
pub const Segment = union(enum) {
    empty,
    field: []const u8,
    arg: usize,
    index: usize,
};

/// Structured information about why a decode operation failed.
///
/// The `tag` discriminates the failure category. Optional fields carry
/// additional context such as the expected type name, the Lua type that
/// was received, or a human-readable detail string. Hooks receive this
/// struct and can branch on `.tag` instead of parsing error messages.
pub const DecodeError = struct {
    /// The category of failure.
    tag: Tag,
    /// The Zig type name of the value the decoder expected, if relevant.
    expected: ?[]const u8 = null,
    /// The Lua primitive tag that was found instead, if relevant.
    got: ?PrimitiveTag = null,
    /// Additional context such as a field name or range information.
    detail: ?[]const u8 = null,

    /// Categories of decode failures.
    pub const Tag = enum {
        /// Expected a different Lua type (e.g. integer but got string).
        wrong_type,
        /// Value was outside the valid range for the target type.
        out_of_range,
        /// Wrong number of Lua arguments (too few, too many).
        invalid_arity,
        /// A required struct field was not present in the Lua table.
        missing_field,
        /// More than one union variant key was set in the Lua table.
        ambiguous_variant,
        /// A non-optional value was nil.
        unexpected_nil,
        /// Catch-all for failures not covered by other tags.
        custom,
    };

    /// Formats the error into a human-readable message.
    ///
    /// The output depends on the tag:
    /// - `wrong_type`: "expected i32, got string"
    /// - `out_of_range`: "u32: integer out of range"
    /// - `invalid_arity`: "invalid arity"
    /// - `missing_field`: "missing field: version"
    pub fn format(self: DecodeError, arena: std.mem.Allocator) ![]const u8 {
        return switch (self.tag) {
            .wrong_type => {
                const exp = self.expected orelse "?";
                const g = if (self.got) |g| @tagName(g) else "?";
                return std.fmt.allocPrint(arena, "expected {s}, got {s}", .{ exp, g });
            },
            .out_of_range => {
                const exp = self.expected orelse "?";
                const d = self.detail orelse "out of range";
                return std.fmt.allocPrint(arena, "{s}: {s}", .{ exp, d });
            },
            .invalid_arity => try std.fmt.allocPrint(arena, "invalid arity", .{}),
            .missing_field => {
                const d = self.detail orelse "missing field";
                return std.fmt.allocPrint(arena, "{s}", .{d});
            },
            .ambiguous_variant => {
                const d = self.detail orelse "ambiguous variant";
                return std.fmt.allocPrint(arena, "{s}", .{d});
            },
            .unexpected_nil => {
                const exp = self.expected orelse "?";
                return std.fmt.allocPrint(arena, "unexpected nil for {s}", .{exp});
            },
            .custom => {
                const d = self.detail orelse "decode failed";
                return std.fmt.allocPrint(arena, "{s}", .{d});
            },
        };
    }
};

/// Active decode position and error target.
///
/// Carries the path buffer, the current nesting depth, and a pointer to
/// the `DecodeError` that will be populated if decoding fails.
/// Passed by value through the pipeline. The path slice and error pointer
/// are shared with the original, so writes to either are visible to the
/// caller regardless of how many times `Trace` is copied.
pub const Trace = struct {
    /// Decode path buffer shared with the original allocation.
    path: []Segment,
    /// Current write position in `path`. Incremented via `child()`.
    deep: usize,
    /// Points to the `DecodeError` that will be set on failure.
    err: *DecodeError,

    /// Returns a new `Trace` one level deeper, sharing the same path and error.
    pub fn child(self: @This()) @This() {
        return .{ .path = self.path, .deep = self.deep + 1, .err = self.err };
    }

    /// Writes `segment` at the current depth and clears the next slot.
    ///
    /// Clearing the next slot ensures the `empty` sentinel stops the formatter
    /// from reading stale segments left by previous sibling fields.
    pub fn set(self: @This(), segment: Segment) void {
        self.path[self.deep] = segment;
        if (self.deep + 1 < self.path.len) self.path[self.deep + 1] = .empty;
    }
};

/// Maximum decode nesting depth for a type or tuple of types.
///
/// Walks struct fields, union variants, and pointer types at compile time
/// to determine the largest path that could be produced when decoding a
/// value of the given type. The result is used to size the path buffer on
/// the caller's stack (no heap allocation).
///
/// Only `.table`, `.alias`, and `.typed_alias` strategy types contribute
/// depth. `.object`, `.ptr`, `.closure`, and `.function` types
/// are opaque to the decoder and counted as 0.
pub fn maxDecodeDepth(comptime types: anytype) usize {
    const Ty = @TypeOf(types);
    if (Ty == type) return depthOf(types) + 1;
    comptime var max: usize = 0;
    inline for (types) |T| {
        const d = depthOf(T);
        if (d > max) max = d;
    }
    return max + 1;
}

/// Formats a path array into a string like `arg0.metadata.version`.
///
/// Walks `path` from the start until `.empty` and joins the human-readable
/// form of each segment. No parameter names are substituted. Use
/// `formatDecodePathArg` when `FnOptions.args` are available.
pub fn formatDecodePath(arena: std.mem.Allocator, path: []const Segment) ![]const u8 {
    return formatDecodePathArg(arena, path, null);
}

/// Formats a path array into a string, using parameter names from `args`.
///
/// Like `formatDecodePath`, but replaces `arg(n)` segments with the
/// parameter name from `args[n].name` when the name is non-empty.
pub fn formatDecodePathArg(arena: std.mem.Allocator, path: []const Segment, args: ?[]const ArgInfo) ![]const u8 {
    var parts = std.ArrayList([]const u8).empty;
    for (path) |seg| {
        switch (seg) {
            .empty => break,
            .arg => |n| {
                const name = if (args) |a|
                    if (n < a.len and a[n].name.len > 0) a[n].name else null
                else
                    null;
                const s = if (name) |nm|
                    nm
                else
                    try std.fmt.allocPrint(arena, "arg{d}", .{n});
                try parts.append(arena, s);
            },
            .field => |name| {
                try parts.append(arena, ".");
                try parts.append(arena, name);
            },
            .index => |i| {
                const s = try std.fmt.allocPrint(arena, "[{d}]", .{i});
                try parts.append(arena, s);
            },
        }
    }
    return try std.mem.join(arena, "", parts.items);
}

fn isOpaqueType(comptime T: type) bool {
    if (comptime @typeInfo(T) != .@"struct" and @typeInfo(T) != .@"union") return false;
    if (comptime @hasDecl(T, "ZUA_SHAPE")) {
        const s = ShapeData.strategyOf(T);
        return s != .table and s != .typed_alias and s != .alias;
    }
    return @typeInfo(T) == .@"union" and @typeInfo(T).@"union".tag_type == null;
}

fn depthOf(comptime T: type) usize {
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (isOpaqueType(T)) return 0;
            comptime var max: usize = 0;
            inline for (@typeInfo(T).@"struct".fields) |field| {
                if (isOpaqueType(field.type)) continue;
                const nd = 1 + depthOf(field.type);
                if (nd > max) max = nd;
            }
            return max;
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and !Internals.isStringValueType(T)) return 1 + depthOf(ptr.child);
            return 0;
        },
        .array => |arr| return 1 + depthOf(arr.child),
        .@"union" => {
            if (isOpaqueType(T)) return 0;
            comptime var max: usize = 0;
            inline for (@typeInfo(T).@"union".fields) |field| {
                if (isOpaqueType(field.type)) continue;
                const nd = 1 + depthOf(field.type);
                if (nd > max) max = nd;
            }
            return max;
        },
        else => return 0,
    }
}
