const std = @import("std");
const lua = @import("../lua/lua.zig");
const translation = @import("translation.zig");
const Zua = @import("zua.zig").Zua;

/// Failure reason for a callback result.
/// - `static_message`: borrowed string constant (commonly error messages from trampoline logic)
/// - `owned_message`: allocator-owned string from formatted error construction
pub const Failure = union(enum) {
    static_message: []const u8,
    owned_message: []const u8,

    /// Extract the error message string from either variant.
    pub fn getErr(self: @This()) []const u8 {
        return switch (self) {
            inline else => |msg| msg,
        };
    }
};

fn isTypeShape(comptime shape: anytype) bool {
    return @TypeOf(shape) == type;
}

fn normalise(comptime shape: anytype) type {
    if (comptime isTypeShape(shape)) {
        return struct { @"0": shape };
    }
    return translation.ParseResult(shape);
}

/// Successful callback result with typed return values.
///
/// Use `Result(T)` for a single return value or `Result(.{ T1, T2, ... })` for multiple.
///
/// Success: call `.ok(value)` for a single value or `.ok(.{ ... })` for multiple values.
///
/// Failure: call `.errStatic(message)` for static strings, `.errOwnedString(message)` for
/// pre-allocated owned strings, or `.errOwned(allocator, fmt, args)` for formatted messages.
/// The trampoline ensures Lua `longjmp` happens after the callback fully returns,
/// so `defer` cleanup runs before the error is raised.
pub fn Result(comptime shape: anytype) type {
    const Tuple = normalise(shape);
    const fields = @typeInfo(Tuple).@"struct".fields;
    const field_count = fields.len;
    const is_single = field_count == 1;
    const SingleT = if (is_single) fields[0].type else void;

    return struct {
        pub const value_types = shape;
        pub const value_count = field_count;
        pub const Value = if (is_single) SingleT else Tuple;

        failure: ?Failure = null,
        values: Tuple = undefined,

        /// Creates a successful callback result.
        pub fn ok(values: if (is_single) SingleT else Tuple) @This() {
            return .{ .values = if (is_single) .{ .@"0" = values } else values };
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

        /// Creates a failed callback result with a pre-allocated owned error message.
        /// Use this when the message is already allocated and owned.
        pub fn errOwnedString(message: []const u8) @This() {
            return .{ .failure = .{ .owned_message = message } };
        }

        /// Single-value accessor. Compile error if called on multi-value results.
        pub fn value(self: @This()) SingleT {
            comptime if (!is_single) @compileError("use .values on multi-value Result");
            return self.values.@"0";
        }

        /// Returns the successful value as an optional, or null on failure.
        pub fn asOption(self: @This()) ?Value {
            if (self.failure != null) return null;
            return if (is_single) self.values.@"0" else self.values;
        }

        /// Pushes all successful values onto the Lua stack.
        pub fn pushValues(self: @This(), z: *Zua) void {
            inline for (fields) |field| {
                translation.pushValue(z, @field(self.values, field.name));
            }
        }

        /// Cast an error result to a different result type.
        pub fn mapErr(self: @This(), comptime K: type) Result(K) {
            std.debug.assert(self.failure != null);
            return Result(K){ .failure = self.failure };
        }

        /// Returns the values if successful, or prints error to stderr and exits.
        /// Mimics Rust's Result::unwrap() behavior.
        pub fn unwrap(self: @This()) if (is_single) SingleT else Tuple {
            if (self.failure) |failure| {
                std.debug.print("thread panicked at '{s}'\n", .{failure.getErr()});
                std.process.exit(1);
            }
            return if (is_single) self.values.@"0" else self.values;
        }
    };
}

/// Promotes Result(T) to Result(?T) by wrapping the value in optional.
/// Used when decoding optional types to wrap successful results.
pub fn promoteOptional(comptime T: type, result: Result(T)) Result(?T) {
    if (result.failure) |failure| {
        return Result(?T).errStatic(failure.getErr());
    }
    return Result(?T).ok(result.unwrap());
}
