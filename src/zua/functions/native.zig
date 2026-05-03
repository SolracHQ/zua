//! High-level Zua callback wrappers for exposing Zig functions to Lua.
const std = @import("std");
const Context = @import("../state/context.zig");
const trampoline = @import("trampoline.zig");

/// Describes how a wrapped callback is invoked from Lua.
///
/// - `hasContext`: the callback accepts `*Context` as its first parameter.
/// - `hasCapture`: the callback accepts a captured state pointer from Lua upvalue 1.
pub const ArgsConfig = trampoline.ArgsConfig;

/// Configuration for wrapper error messages and hooks.
///
/// This controls how argument decoding failures and Zig errors are reported
/// when the callback is called from Lua.
pub const ErrorConfig = trampoline.ErrorConfig;
pub const ArgInfo = trampoline.ArgInfo;
pub const DocOptions = trampoline.DocOptions;

// Public type constructors used in signatures (e.g. return type annotations).

/// Creates a concrete `NativeFn` wrapper type for the provided Zig callback.
///
/// The returned type exposes `trampoline()` for registration with Lua and
/// automatically injects `*Context` when the callback accepts it as the first
/// parameter.
///
/// Arguments:
/// - `function`: the Zig callback to expose to Lua.
/// - `error_config`: parsing and Zig error formatting hooks for the wrapped callback.
/// - `doc`: optional documentation metadata for stub generation.
///
/// Returns:
/// - `type`: a concrete wrapper type whose `trampoline()` method can be pushed to Lua.
///
/// Example:
/// ```zig
/// const my_fn = zua.Native.new(add, .{ .parse_err_fmt = "add expects (number, number): {s}" }, .{});
/// globals.set(&ctx, "add", my_fn);
/// ```
pub fn NativeFn(comptime function: anytype, comptime error_config: ErrorConfig, comptime doc: DocOptions) type {
    const FunctionType = @TypeOf(function);
    if (comptime @typeInfo(FunctionType) != .@"fn") {
        @compileError("NativeFn expects a function, got " ++ @typeName(FunctionType));
    }

    const fn_info = comptime @typeInfo(FunctionType).@"fn";
    const has_context = comptime fn_info.params.len > 0 and
        fn_info.params[0].type != null and
        fn_info.params[0].type.? == *Context;

    return trampoline.make(function, .{ .hasContext = has_context }, error_config, doc);
}

/// Creates a concrete `Closure` wrapper type for the provided Zig callback.
///
/// The returned type carries `initial` as captured state and exposes
/// `__IsZuaClosure` so the encoder can push the wrapper as a Lua C closure
/// with one upvalue.
///
/// Arguments:
/// - `function`: the Zig callback to expose to Lua.
/// - `error_config`: parsing and Zig error formatting hooks for the wrapped callback.
/// - `doc`: optional documentation metadata for stub generation.
///
/// Returns:
/// - `type`: a concrete closure wrapper type that carries the initial capture value.
///
/// Example:
/// ```zig
/// const counter = zua.Native.closure(counter_fn, CounterState{ .count = 0, .step = 1 }, .{}, .{});
/// globals.set(&ctx, "counter", counter);
/// ```
pub fn Closure(comptime function: anytype, comptime error_config: ErrorConfig, comptime doc: DocOptions) type {
    const FunctionType = @TypeOf(function);
    if (comptime @typeInfo(FunctionType) != .@"fn") {
        @compileError("Closure expects a function, got " ++ @typeName(FunctionType));
    }

    const fn_info = comptime @typeInfo(FunctionType).@"fn";
    comptime trampoline.validateCapturePosition(fn_info);

    const has_context = comptime fn_info.params.len > 0 and
        fn_info.params[0].type != null and
        fn_info.params[0].type.? == *Context;

    return trampoline.make(function, .{ .hasContext = has_context, .hasCapture = true }, error_config, doc);
}

// Value constructors used at call sites.

/// Creates a wrapper value for the given callback using an explicit error config.
///
/// This helper is intended for cases where the caller needs to customize
/// `ErrorConfig` directly. In ordinary push paths, the wrapper is already
/// constructed by the encoder and this helper is not required.
///
/// Arguments:
/// - `function`: the Zig callback to expose to Lua.
/// - `error_config`: parsing and Zig error formatting hooks.
/// - `doc`: optional documentation metadata for stub generation.
///
/// Returns:
/// - `NativeFn`: a concrete wrapper value ready to be pushed to Lua.
///
/// Example:
/// ```zig
/// const fn_val = zua.Native.new(add, .{ .parse_err_fmt = "add expects (number, number): {s}" }, .{});
/// globals.set(&ctx, "add", fn_val);
/// ```
pub inline fn new(comptime function: anytype, comptime error_config: ErrorConfig, comptime doc: DocOptions) NativeFn(function, error_config, doc) {
    return .{};
}

/// Creates a closure wrapper value that bundles `initial` as captured state.
///
/// The callback must accept a `*CaptureType` parameter whose type declares
/// `ZUA_META` with a `.capture` strategy. The capture parameter must be first
/// after `*Context` (if present), or first otherwise.
///
/// Arguments:
/// - `function`: the Zig callback to expose to Lua.
/// - `initial`: the initial capture state passed as userdata upvalue 1.
/// - `error_config`: parsing and Zig error formatting hooks.
/// - `doc`: optional documentation metadata for stub generation.
///
/// Returns:
/// - `Closure`: a concrete closure wrapper value that carries the capture state.
///
/// Example:
/// ```zig
/// const counter = zua.Native.closure(counter_fn, CounterState{ .count = 0, .step = 1 }, .{}, .{});
/// globals.set(&ctx, "counter", counter);
/// ```
pub inline fn closure(
    comptime function: anytype,
    initial: anytype,
    comptime error_config: ErrorConfig,
    comptime doc: DocOptions,
) Closure(function, error_config, doc) {
    return .{ .initial = initial };
}

test {
    std.testing.refAllDecls(@This());
}
