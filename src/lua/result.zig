const std = @import("std");
const lua = @import("lua.zig");
const decode = @import("decode.zig");
const Table = @import("table.zig").Table;

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

        /// Creates a successful single-value callback result, cloning owned string values.
        pub fn owned(allocator: std.mem.Allocator, value: T) @This() {
            if (comptime !isOwnedResultValueType(T)) {
                return .{ .value = value };
            }

            const cloned = cloneResultValue(T, allocator, value) catch {
                return @This().errStatic("out of memory");
            };

            return .{
                .value = cloned,
                .owns_value = true,
            };
        }

        /// Creates a failed callback result with a borrowed static error message.
        pub fn errStatic(message: []const u8) @This() {
            return .{ .failure = .{ .static_message = message } };
        }

        /// Creates a failed callback result with an allocator-owned formatted error message.
        pub fn errOwned(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) @This() {
            const message = std.fmt.allocPrint(allocator, fmt, args) catch {
                return @This().errStatic("out of memory");
            };

            return .{ .failure = .{ .owned_message = message } };
        }

        /// Creates a failed callback result from a Zig error value.
        pub fn errZig(err: anyerror) @This() {
            return .{ .failure = .{ .zig_error = err } };
        }

        /// Pushes the successful value onto the Lua stack.
        pub fn pushValues(self: @This(), state: *lua.State, allocator: std.mem.Allocator) void {
            Table.pushValueToStack(state, allocator, self.value);
        }

        /// Releases any owned memory associated with this result.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (!self.owns_value) return;
            freeResultValue(T, allocator, self.value);
        }
    };
}

fn MultiResult(comptime types: anytype) type {
    return struct {
        pub const value_types = types;
        pub const value_count = types.len;
        pub const ValueTuple = decode.ParseResult(types);

        failure: ?Failure = null,
        values: ValueTuple = undefined,
        owned_values: [types.len]bool = [_]bool{false} ** types.len,

        /// Creates a successful multi-value callback result.
        pub fn ok(values: ValueTuple) @This() {
            return .{ .values = values };
        }

        /// Creates a successful multi-value callback result, cloning owned string values.
        pub fn owned(allocator: std.mem.Allocator, values: ValueTuple) @This() {
            var result = @This().ok(values);

            inline for (types, 0..) |T, index| {
                if (comptime isOwnedResultValueType(T)) {
                    result.values[index] = cloneResultValue(T, allocator, values[index]) catch {
                        result.deinit(allocator);
                        return @This().errStatic("out of memory");
                    };
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
        pub fn errOwned(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) @This() {
            const message = std.fmt.allocPrint(allocator, fmt, args) catch {
                return @This().errStatic("out of memory");
            };

            return .{ .failure = .{ .owned_message = message } };
        }

        /// Creates a failed callback result from a Zig error value.
        pub fn errZig(err: anyerror) @This() {
            return .{ .failure = .{ .zig_error = err } };
        }

        /// Pushes all successful values onto the Lua stack.
        pub fn pushValues(self: @This(), state: *lua.State, allocator: std.mem.Allocator) void {
            inline for (types, 0..) |_, index| {
                Table.pushValueToStack(state, allocator, self.values[index]);
            }
        }

        /// Releases any owned memory associated with this result.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            inline for (types, 0..) |T, index| {
                if (self.owned_values[index]) {
                    freeResultValue(T, allocator, self.values[index]);
                }
            }
        }
    };
}
