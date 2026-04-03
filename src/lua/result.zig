const std = @import("std");
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

/// Successful callback result with typed return values.
///
/// Callbacks register with `Table.setFn` and must return `Result(.{ T1, T2, ... })` where
/// the tuple contains the types of values to push back to Lua.
///
/// Success: call `.ok(values)` to return typed values without ownership transfer,
/// or `.owned(allocator, values)` if the values contain strings that need cloning.
///
/// Failure: call `.errStatic(message)` for static strings, `.errOwned(message)` for
/// allocator-owned strings, or `.errZig(error)` to surface a Zig error.
/// The trampoline ensures Lua `longjmp` happens after the callback fully returns,
/// so `defer` cleanup runs before the error is raised.
pub fn Result(comptime types: anytype) type {
    return struct {
        pub const value_types = types;
        pub const ValueTuple = decode.ParseResult(types);

        failure: ?Failure = null,
        values: ValueTuple = undefined,
        owned_values: [types.len]bool = [_]bool{false} ** types.len,

        /// Creates a successful callback result with typed return values (borrowed).
        pub fn ok(values: ValueTuple) @This() {
            return .{ .values = values };
        }

        /// Creates a successful callback result and duplicates returned string values.
        /// Use this when returning temporary allocated strings (e.g., from allocPrint).
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

        /// Creates a callback result with a borrowed static error message.
        pub fn errStatic(message: []const u8) @This() {
            return .{ .failure = .{ .static_message = message } };
        }

        /// Creates a callback result with an allocator-owned error message.
        pub fn errOwned(message: []const u8) @This() {
            return .{ .failure = .{ .owned_message = message } };
        }

        /// Creates a callback result from a Zig error value.
        pub fn errZig(err: anyerror) @This() {
            return .{ .failure = .{ .zig_error = err } };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            inline for (types, 0..) |T, index| {
                if (self.owned_values[index]) {
                    freeResultValue(T, allocator, self.values[index]);
                }
            }
        }
    };
}
