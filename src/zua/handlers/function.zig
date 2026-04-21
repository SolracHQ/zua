//! Function handles wrap Lua functions so they can be safely called from Zig.
//! They support borrowed, stack-owned, and registry-owned lifetimes and
//! centralize the logic for pushing arguments, calling Lua, and decoding results.
const std = @import("std");
const lua = @import("../../lua/lua.zig");
const Handle = @import("../handlers/handlers.zig").Handle;
const Mapper = @import("../mapper/mapper.zig");
const State = @import("../state/state.zig");
const Context = @import("../state/context.zig").Context;
const MetaTable = @import("../metatable.zig");

/// Errors returned by function calls.
pub const Error = error{Failed};

/// Handle to a Lua function with three ownership modes: borrowed, stack_owned, or registry_owned.
pub const Function = @This();

/// Global Zua state pointer used to access the Lua VM and allocators.
/// This pointer is borrowed by the handle and is not owned by `Function`.
state: *State,
/// Ownership mode for the referenced Lua function value.
/// The handle may represent a borrowed stack slot, a stack-owned slot, or a registry reference.
handle: Handle,

/// Creates a borrowed function handle for a stack slot owned by another API operation.
/// The borrowed handle does not own the stack slot and must not be released.
///
/// Arguments:
/// - state: The global Zua state containing the Lua VM.
/// - index: The stack index of the borrowed function.
///
/// Returns:
/// - Function: A borrowed function handle.
///
/// Example:
/// ```zig
/// const fn_handle = Function.fromBorrowed(state, 1);
/// ```
pub fn fromBorrowed(state: *State, index: lua.StackIndex) Function {
    return .{
        .state = state,
        .handle = .{ .borrowed = lua.absIndex(state.luaState, index) },
    };
}

/// Creates a stack-owned function handle that must be released via `release()`.
///
/// Arguments:
/// - state: The global Zua state containing the Lua VM.
/// - index: The stack index of the owned function.
///
/// Returns:
/// - Function: A stack-owned function handle.
///
/// Example:
/// ```zig
/// var fn_handle = Function.fromStack(state, -1);
/// defer fn_handle.release();
/// ```
pub fn fromStack(state: *State, index: lua.StackIndex) Function {
    return .{
        .state = state,
        .handle = .{ .stack_owned = lua.absIndex(state.luaState, index) },
    };
}

/// Creates a new Lua function handle from a Zig callback or an existing
/// `ZuaFn` wrapper.
///
/// This is a convenience helper for constructing raw function handles from
/// native Zig callbacks or pre-wrapped ZuaFn values.
///
/// Arguments:
/// - state: The global Zua state containing the Lua VM.
/// - callback: A Zig function or a `ZuaFn`/`ZuaFn.newClosure` wrapper.
///
/// Returns:
/// - Function: A stack-owned handle for the pushed Lua function.
///
/// Example:
/// ```zig
/// const fn_handle = Function.create(state, my_native_callback);
/// const fn_handle = Function.create(state, zua.ZuaFn.new(my_callback, .{}));
/// ```
pub fn create(state: *State, callback: anytype) Function {
    const CallbackType = @TypeOf(callback);

    if (comptime @typeInfo(CallbackType) == .@"fn" or
        (@typeInfo(CallbackType) == .@"struct" and @hasDecl(CallbackType, "__IsZuaFn")))
    {
        var ctx = Context.init(state);
        defer ctx.deinit();
        Mapper.Encoder.pushValue(&ctx, callback) catch @panic("This must never happen, push a function to lua cannot fail in the zig sense, lua will just panic, so if you see this, please report a bug");
        return Function.fromStack(state, -1);
    }

    @compileError("Function.create expects a Zig function or a NativeFn/Closure wrapper");
}

/// Calls the Lua function with the given arguments and decodes return values.
/// The function is pushed onto the stack, arguments are encoded, and the Lua call
/// result is parsed into `res_types`.
///
/// Arguments:
/// - ctx: The current call context used for encoding and error handling.
/// - args: The argument tuple to pass to the Lua function.
/// - res_types: The expected return type tuple for decoding.
///
/// Returns:
/// - !Mapper.Decoder.ParseResult(res_types): Parsed return values on success.
/// - error.Failed: When the Lua call fails or return decoding fails.
///
/// Example:
/// ```zig
/// const result = try fn_handle.call(ctx, .{1, 2}, .{i32});
/// ```
pub fn call(self: Function, ctx: *Context, args: anytype, comptime res_types: anytype) !Mapper.Decoder.ParseResult(res_types) {
    const previous_top = lua.getTop(self.state.luaState);

    // Push function onto stack
    switch (self.handle) {
        .borrowed, .stack_owned => |idx| lua.pushValue(self.state.luaState, idx),
        .registry_owned => |ref| _ = lua.rawGetI(self.state.luaState, lua.REGISTRY_INDEX, ref),
    }

    // Push arguments
    const ArgsTuple = @TypeOf(args);
    const arg_count = @typeInfo(ArgsTuple).@"struct".fields.len;
    inline for (args) |arg| {
        try Mapper.Encoder.pushValue(ctx, arg);
    }

    // Call the function
    lua.protectedCall(self.state.luaState, arg_count, lua.MULT_RETURN, 0) catch {
        // Extract error message from Lua stack
        const error_msg = lua.toString(self.state.luaState, -1) orelse "unknown error";
        const owned_msg = ctx.arena().dupe(u8, error_msg) catch {
            lua.pop(self.state.luaState, 1);
            return try ctx.failTyped(Mapper.Decoder.ParseResult(res_types), "out of memory");
        };
        lua.pop(self.state.luaState, 1);
        ctx.err = owned_msg;
        return error.Failed;
    };

    // Parse return values
    const result_count = lua.getTop(self.state.luaState) - previous_top;

    const parsed_values = try Mapper.Decoder.parseTuple(ctx, previous_top + 1, result_count, res_types);

    // Pop results from stack
    lua.pop(self.state.luaState, result_count);

    return parsed_values;
}

/// Anchors this function in the Lua registry for persistent storage.
/// The returned handle owns the registry reference and remains valid after the
/// current stack frame is unwound.
///
/// Returns:
/// - Function: A registry-owned function handle.
///
/// Example:
/// ```zig
/// const owned_fn = fn_handle.owned();
/// defer owned_fn.release();
/// ```
pub fn owned(self: Function) Function {
    return .{
        .state = self.state,
        .handle = self.handle.owned(self.state),
    };
}

/// Anchors this function in the Lua registry and removes the old stack-owned
/// handle if applicable.
pub fn takeOwnership(self: Function) Function {
    return .{
        .state = self.state,
        .handle = self.handle.takeOwnership(self.state),
    };
}

/// Releases this function from the stack (if stack-owned) or registry (if registry-owned).
///
/// Example:
/// ```zig
/// fn_handle.release();
/// ```
pub fn release(self: Function) void {
    self.handle.release(self.state);
}

test {
    std.testing.refAllDecls(@This());
}
