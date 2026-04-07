const std = @import("std");
const lua = @import("../lua/lua.zig");
const translation = @import("translation.zig");
const Result = @import("result.zig").Result;
const Zua = @import("zua.zig").Zua;

/// Errors returned by function calls.
pub const Error = translation.ParseError;

/// Handle to a Lua function with three ownership modes: borrowed, stack_owned, or registry_owned.
pub fn Function(comptime types: anytype) type {
    return struct {
        z: *Zua,
        handle: union(translation.HandleOwnership) {
            borrowed: lua.StackIndex,
            stack_owned: lua.StackIndex,
            registry_owned: c_int,
        },

        /// Marker to identify Function types at compile time.
        pub const __isZuaFunction = true;

        /// Creates a borrowed function handle for a stack slot owned by some other API.
        pub fn fromBorrowed(z: *Zua, index: lua.StackIndex) @This() {
            return .{
                .z = z,
                .handle = .{ .borrowed = lua.absIndex(z.state, index) },
            };
        }

        /// Creates a stack-owned function handle that must be released via .release().
        pub fn fromStack(z: *Zua, index: lua.StackIndex) @This() {
            return .{
                .z = z,
                .handle = .{ .stack_owned = lua.absIndex(z.state, index) },
            };
        }

        /// Calls the Lua function with the given arguments.
        /// Returns Result wrapping success or error with message.
        pub fn call(self: @This(), args: anytype) !Result(types) {
            const previous_top = lua.getTop(self.z.state);

            // Push function onto stack
            switch (self.handle) {
                .borrowed, .stack_owned => |idx| lua.pushValue(self.z.state, idx),
                .registry_owned => |ref| _ = lua.rawGetI(self.z.state, lua.REGISTRY_INDEX, ref),
            }

            // Push arguments
            const ArgsTuple = @TypeOf(args);
            const arg_count = @typeInfo(ArgsTuple).@"struct".fields.len;
            inline for (args) |arg| {
                translation.pushValue(self.z, arg);
            }

            // Call the function
            lua.protectedCall(self.z.state, arg_count, lua.MULT_RETURN, 0) catch {
                // Extract error message from Lua stack
                const error_msg = lua.toString(self.z.state, -1) orelse "unknown error";
                const owned_msg = self.z.allocator.dupe(u8, error_msg) catch {
                    lua.pop(self.z.state, 1);
                    return Result(types).errStatic("out of memory");
                };
                lua.pop(self.z.state, 1);
                return Result(types).errOwnedString(owned_msg);
            };

            // Parse return values
            const result_count = lua.getTop(self.z.state) - previous_top;
            const parsed_result = try translation.parseTuple(
                self.z,
                previous_top + 1,
                result_count,
                types,
                .borrowed,
            );

            // Check if parseTuple returned a failure
            if (parsed_result.failure) |failure| {
                lua.pop(self.z.state, result_count);
                return Result(types){ .failure = failure };
            }

            // Pop results from stack
            lua.pop(self.z.state, result_count);

            const parsed_values = parsed_result.unwrap();
            const is_single = Result(types).value_count == 1;
            return if (is_single)
                Result(types).ok(parsed_values.@"0")
            else
                Result(types).ok(parsed_values);
        }

        /// Anchors this function in the Lua registry for persistent storage.
        /// Must be called before the enclosing callback returns.
        pub fn takeOwnership(self: @This()) @This() {
            const index = switch (self.handle) {
                inline else => |idx| idx,
            };

            // Push the function onto the stack
            lua.pushValue(self.z.state, index);

            // Store in registry
            const ref = lua.ref(self.z.state, lua.REGISTRY_INDEX);

            return .{
                .z = self.z,
                .handle = .{ .registry_owned = ref },
            };
        }

        /// Releases this function from the stack (if stack-owned) or registry (if registry-owned).
        pub fn release(self: @This()) void {
            switch (self.handle) {
                .borrowed => {},
                .stack_owned => |index| lua.remove(self.z.state, index),
                .registry_owned => |ref| lua.unref(self.z.state, lua.REGISTRY_INDEX, ref),
            }
        }

        /// Frees an owned error message from a failed call.
        pub fn freeError(self: @This(), msg: []const u8) void {
            self.z.allocator.free(msg);
        }
    };
}
