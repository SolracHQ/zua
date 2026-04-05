const std = @import("std");
const lua = @import("../lua/lua.zig");
const translation = @import("translation.zig");
const Zua = @import("zua.zig").Zua;

/// Failure reason for a callback result.
/// - `static_message`: borrowed string constant (commonly error messages from trampoline logic)
/// - `owned_message`: allocator-owned string from formatted error construction
/// - `zig_error`: anyerror from Zig code (converted to error name string by trampoline)
pub const Failure = union(enum) {
    static_message: []const u8,
    owned_message: []const u8,
    zig_error: anyerror,
};

fn isOwnedResultValueType(comptime T: type) bool {
    return T == []const u8 or T == [:0]const u8;
}

fn cloneResultValue(comptime T: type, allocator: std.mem.Allocator, value: T) !T {
    if (T == []const u8) return try allocator.dupe(u8, value);
    if (T == [:0]const u8) return try allocator.dupeZ(u8, value);
    return value;
}

fn freeResultValue(comptime T: type, allocator: std.mem.Allocator, value: T) void {
    if (T == []const u8 or T == [:0]const u8) {
        allocator.free(value);
    }
}

fn isTypeShape(comptime shape: anytype) bool {
    return @TypeOf(shape) == type;
}

/// Successful callback result with typed return values.
///
/// Use `Result(T)` for a single return value or `Result(.{ T1, T2, ... })` for multiple.
///
/// Success: call `.ok(value)` / `.owned(allocator, value)` for a single value,
/// or `.ok(.{ ... })` / `.owned(allocator, .{ ... })` for multiple values.
///
/// Failure: call `.errStatic(message)` for static strings, `.errOwned(message)` for
/// allocator-owned strings, or `.errZig(error)` to surface a Zig error.
/// The trampoline ensures Lua `longjmp` happens after the callback fully returns,
/// so `defer` cleanup runs before the error is raised.
pub fn Result(comptime shape: anytype) type {
    if (comptime isTypeShape(shape)) {
        return SingleResult(shape);
    }

    return MultiResult(shape);
}

fn SingleResult(comptime T: type) type {
    return struct {
        pub const value_types = .{T};
        pub const value_count = 1;
        pub const Value = T;

        failure: ?Failure = null,
        value: T = undefined,
        owns_value: bool = false,

        /// Creates a successful single-value callback result.
        pub fn ok(value: T) @This() {
            return .{ .value = value };
        }

        /// Creates a successful single-value callback result, taking ownership of allocated values.
        /// The value must be allocated with z.allocator. It will be freed after the callback returns.
        pub fn owned(value: T) @This() {
            if (comptime !isOwnedResultValueType(T)) {
                return .{ .value = value };
            }

            return .{
                .value = value,
                .owns_value = true,
            };
        }

        /// Creates a failed callback result with a borrowed static error message.
        pub fn errStatic(message: []const u8) @This() {
            return .{ .failure = .{ .static_message = message } };
        }

        /// Creates a failed callback result with an allocator-owned formatted error message.
        pub fn errOwned(z: *Zua, comptime fmt: []const u8, args: anytype) @This() {
            const message = std.fmt.allocPrint(z.allocator, fmt, args) catch {
                return @This().errStatic("out of memory");
            };

            return .{ .failure = .{ .owned_message = message } };
        }

        /// Creates a failed callback result from a Zig error value.
        pub fn errZig(err: anyerror) @This() {
            return .{ .failure = .{ .zig_error = err } };
        }

        /// Pushes the successful value onto the Lua stack.
        pub fn pushValues(self: @This(), z: *Zua) void {
            translation.pushValue(z, self.value);
        }

        /// Releases any owned memory associated with this result.
        pub fn deinit(self: *@This(), z: *Zua) void {
            if (!self.owns_value) return;
            freeResultValue(T, z.allocator, self.value);
        }
    };
}

fn MultiResult(comptime types: anytype) type {
    return struct {
        pub const value_types = types;
        pub const value_count = types.len;
        pub const ValueTuple = translation.ParseResult(types);

        failure: ?Failure = null,
        values: ValueTuple = undefined,
        owned_values: [types.len]bool = [_]bool{false} ** types.len,

        /// Creates a successful multi-value callback result.
        pub fn ok(values: ValueTuple) @This() {
            return .{ .values = values };
        }

        /// Creates a successful multi-value callback result, taking ownership of allocated string values.
        /// String values must be allocated with z.allocator. They will be freed after the callback returns.
        pub fn owned(values: ValueTuple) @This() {
            var result = @This().ok(values);

            inline for (types, 0..) |T, index| {
                if (comptime isOwnedResultValueType(T)) {
                    result.owned_values[index] = true;
                }
            }

            return result;
        }

        /// Creates a failed callback result with a borrowed static error message.
        pub fn errStatic(message: []const u8) @This() {
            return .{ .failure = .{ .static_message = message } };
        }

        /// Creates a failed callback result with an allocator-owned formatted error message.
        pub fn errOwned(z: *Zua, comptime fmt: []const u8, args: anytype) @This() {
            const message = std.fmt.allocPrint(z.allocator, fmt, args) catch {
                return @This().errStatic("out of memory");
            };

            return .{ .failure = .{ .owned_message = message } };
        }

        /// Creates a failed callback result from a Zig error value.
        pub fn errZig(err: anyerror) @This() {
            return .{ .failure = .{ .zig_error = err } };
        }

        /// Pushes all successful values onto the Lua stack.
        pub fn pushValues(self: @This(), z: *Zua) void {
            inline for (types, 0..) |_, index| {
                translation.pushValue(z, self.values[index]);
            }
        }

        /// Releases any owned memory associated with this result.
        pub fn deinit(self: *@This(), z: *Zua) void {
            inline for (types, 0..) |T, index| {
                if (self.owned_values[index]) {
                    freeResultValue(T, z.allocator, self.values[index]);
                }
            }
        }
    };
}
