//! Wraps a Zig function for Lua callers.
//!
//! `Shape.Fn(fn, .{ ... })` converts any Zig function into a callable Lua
//! C function. Arguments are decoded from the Lua stack automatically
//! based on the function signature. `*Context` as the first parameter is
//! injected automatically. Returns are pushed back to Lua.

const std = @import("std");
const Context = @import("../state/context.zig");
const trampoline = @import("trampoline.zig");

/// Describes one parameter of a Zig function for Lua annotation generation.
///
/// Attach these to `FnOptions.args` so the docs generator produces
/// `---@param name description` lines with proper parameter names instead
/// of generic `arg1`, `arg2`, etc.
pub const ArgInfo = struct {
    /// The parameter name as it appears in the Lua annotation.
    name: []const u8,
    /// Optional description shown after the type in `---@param`.
    description: ?[]const u8 = null,
};

/// Options passed to `Shape.Fn` to attach documentation metadata.
///
/// All fields are optional. Use `.{}` or omit for bare-bones wrapping.
///
/// Example:
/// ```zig
/// const my_fn = zua.Shape.Fn(add, .{
///     .description = "Adds two integers together.",
///     .args = &.{
///         .{ .name = "a", .description = "First addend." },
///         .{ .name = "b", .description = "Second addend." },
///     },
/// });
/// ```
pub const FnOptions = struct {
    /// Description shown as a `--` comment before the function definition
    /// in generated Lua stubs.
    description: []const u8 = "",

    /// Parameter metadata for docs. Each entry describes one Lua argument
    /// in order, excluding `*Context` and `*T` (those are injected
    /// automatically and never appear in annotations).
    args: []const ArgInfo = &.{},

    /// Optional hook called when argument decoding fails at runtime.
    /// The hook receives the error message and can override it by setting
    /// `ctx.err`. If unset, the default decoder message is used as-is.
    parse_err_hook: ?fn (*Context, []const u8) void = null,
};

/// Wraps a Zig function so it can be called from Lua.
///
/// `Shape.Fn(fn, options)` returns a type. The type IS the value — assign
/// it directly to a struct field or pass it to `addBinding` without
/// creating an instance.
///
/// The wrapper auto-detects `*Context` as the first parameter and injects
/// the current call context. Parameters after context (or the first param
/// if context is absent) are decoded from Lua arguments in order. VarArgs
/// as the last parameter captures remaining Lua values. The return value
/// is pushed back to Lua: single values directly, tuples as multiple
/// returns, `void` as no return.
///
/// Example:
/// ```zig
/// const module = .{
///     .add = zua.Shape.Fn(add, .{ .description = "Adds two integers." }),
///     .greet = zua.Shape.Fn(greet, .{ .description = "Greets a user." }),
/// };
/// try state.addGlobals(&ctx, module);
/// ```
pub fn Fn(comptime function: anytype, comptime options: FnOptions) type {
    const FunctionType = @TypeOf(function);
    if (comptime @typeInfo(FunctionType) != .@"fn") {
        @compileError("Fn expects a function, got " ++ @typeName(FunctionType));
    }

    const fn_info = comptime @typeInfo(FunctionType).@"fn";
    const has_context = comptime fn_info.params.len > 0 and
        fn_info.params[0].type != null and
        fn_info.params[0].type.? == *Context;

    return trampoline.makeFn(function, has_context, options);
}

test {
    std.testing.refAllDecls(@This());
}
