//! ZuaFn wraps Zig callbacks for Lua by decoding arguments, executing the
//! function, and pushing return values. It supports optional context
//! injection, capture (closure) injection via Lua upvalues, configurable
//! error formatting hooks, and a trampoline that raises Lua errors for failures.
const std = @import("std");
const lua = @import("../../lua/lua.zig");
const Mapper = @import("../mapper/mapper.zig");
const Meta = @import("../meta.zig");
const State = @import("../state/state.zig");
const Context = @import("../state/context.zig");

/// Callback kind indicates how the wrapped function's leading parameters are handled.
const CallbackKind = enum {
    /// First parameter is `*Context`, rest are decoded from the Lua stack.
    with_zua,
    /// No context or capture, all parameters decoded from the Lua stack.
    pure,
    /// First parameter is `*Context`, second is `*CaptureType` from upvalue 1,
    /// rest decoded from the Lua stack.
    with_zua_and_capture,
    /// First parameter is `*CaptureType` from upvalue 1, rest decoded.
    with_capture,
};

/// Configuration for `ZuaFn` error handling.
pub const ZuaFnErrorConfig = struct {
    /// Format string for argument decoding failures.
    parse_err_fmt: []const u8 = "argument decoding failed: {s}",

    /// Hook called when argument decoding fails.
    /// It takes precedence over `parse_err_fmt` and sets `ctx.err` to the provided error message.
    parse_err_hook: ?fn (
        *Context,
        actual_lua_type: lua.Type,
        failed_index: lua.StackIndex,
        error_message: []const u8,
    ) void = null,

    /// Format string for Zig errors. Receives the error name as `{s}`.
    zig_err_fmt: []const u8 = "Zig error: {s}",

    /// Hook called when the wrapped function raises a Zig error.
    /// It takes precedence over `zig_err_fmt`, sets `ctx.err` to the error
    /// message, and returns nothing.
    zig_err_hook: ?fn (*Context, anyerror) void = null,
};

/// Creates a concrete `ZuaFn` wrapper value for the provided Zig callback.
///
/// The returned wrapper is a compile-time generated value whose `trampoline()`
/// method can be used as a Lua C function. The wrapper also participates in
/// the encoder/decoder metadata pipeline, so it can be registered as a global
/// Lua function, stored inside Lua values, or returned from callbacks.
///
/// Arguments:
/// - function: The Zig callback to expose to Lua.
/// - error_config: Parsing and Zig error formatting hooks for the wrapped callback.
///
/// Returns:
/// - type: A concrete wrapper value of the generated `ZuaFn` type.
///
/// Example:
/// ```zig
/// const my_fn = zua.ZuaFn.new(add, .{ .parse_err_fmt = "add expects (number, number): {s}" });
/// globals.set(&ctx, "add", my_fn);
/// ```
pub fn new(comptime function: anytype, comptime error_config: ZuaFnErrorConfig) ZuaFnType(function, error_config) {
    return .{};
}

/// Creates a closure wrapper that bundles `initial` as captured state in upvalue 1.
///
/// The callback must accept a `*CaptureType` parameter whose struct declares
/// `pub const ZUA_META = zua.Meta.Capture(...)`. The capture parameter must be
/// the first parameter after `*Context` (if present), or the very first
/// parameter otherwise.
///
/// Each time the returned value is pushed to Lua (e.g. via `globals.set`), a
/// fresh copy of `initial` is allocated as userdata and bundled into the
/// closure. Mutations through the `*CaptureType` pointer persist across calls
/// to the same closure instance.
///
/// Arguments:
/// - function: The Zig callback. Must contain exactly one capture parameter.
/// - initial: The initial value for the captured state.
/// - error_config: Parsing and Zig error formatting hooks.
///
/// Returns:
/// - A concrete wrapper value whose `__IsZuaClosure` marker tells the encoder
///   to push it as a C closure with one upvalue.
///
/// Example:
/// ```zig
/// const fn_val = zua.ZuaFn.newClosure(counter, CounterState{ .count = 0, .step = 1 }, .{});
/// globals.set(&ctx, "counter", fn_val);
/// ```
pub fn newClosure(
    comptime function: anytype,
    initial: anytype,
    comptime error_config: ZuaFnErrorConfig,
) ZuaFnClosureType(function, error_config) {
    return .{ .initial = initial };
}

/// Computes the concrete wrapper type for a Zig callback and error-handling config.
///
/// The returned type is a statically generated Lua trampoline wrapper that
/// decodes Lua arguments, invokes the underlying Zig function, and pushes the
/// results back to Lua. If the callback accepts `*Context` as its first
/// parameter, the wrapper injects the current `Context` automatically.
///
/// Arguments:
/// - function: The Zig callback to expose to Lua.
/// - error_config: Parsing and Zig error formatting hooks for the wrapped callback.
///
/// Returns:
/// - type: A concrete wrapper type whose `trampoline()` method can be used as a
///   Lua C function.
pub fn ZuaFnType(comptime function: anytype, comptime error_config: ZuaFnErrorConfig) type {
    const FunctionType = @TypeOf(function);
    if (comptime @typeInfo(FunctionType) != .@"fn") {
        @compileError("ZuaFn.new expects a function type but got " ++ @typeName(FunctionType));
    }

    const fn_info = @typeInfo(FunctionType).@"fn";
    if (fn_info.params.len > 0) {
        const first_param = fn_info.params[0].type orelse @compileError("callback parameters must have concrete types");
        if (first_param == *Context) {
            return ZuaFn(function, .with_zua, error_config);
        }
    }
    return ZuaFn(function, .pure, error_config);
}

/// Computes the concrete closure wrapper type for a Zig callback.
///
/// Like `ZuaFnType` but the returned type carries an `initial` field and
/// exposes `__IsZuaClosure` so the encoder bundles the initial capture as
/// upvalue 1 via `lua_pushcclosure`.
pub fn ZuaFnClosureType(comptime function: anytype, comptime error_config: ZuaFnErrorConfig) type {
    const FunctionType = @TypeOf(function);
    if (comptime @typeInfo(FunctionType) != .@"fn") {
        @compileError("ZuaFn.newClosure expects a function type but got " ++ @typeName(FunctionType));
    }

    const fn_info = @typeInfo(FunctionType).@"fn";
    comptime validateCapturePosition(fn_info);

    const has_context = fn_info.params.len > 0 and
        fn_info.params[0].type != null and
        fn_info.params[0].type.? == *Context;

    const kind: CallbackKind = if (has_context) .with_zua_and_capture else .with_capture;
    return ZuaFn(function, kind, error_config);
}

/// Generates the internal wrapper type for a function, the callback kind, and the error handling configuration. The returned type exposes `trampoline()` for use as a Lua C function.
fn ZuaFn(comptime function: anytype, comptime kind: CallbackKind, comptime error_config: ZuaFnErrorConfig) type {
    const FunctionType = @TypeOf(function);
    const function_info = @typeInfo(FunctionType).@"fn";
    const ReturnType = function_info.return_type orelse
        @compileError("callback must have a return type");
    const ActualReturnType = unwrapErrorUnion(ReturnType);

    comptime validateKind(kind, function_info);
    comptime validateVarArgs(function_info);

    // The capture type is the pointee of the capture parameter (a *T).
    // For non-closure kinds this is void and unused.
    const CaptureType: type = if (comptime kind == .with_capture or kind == .with_zua_and_capture)
        captureParamPointee(function_info)
    else
        void;

    return struct {
        pub const __IsZuaFn = true;
        // Closure marker: present and true only on closure wrappers.
        pub const __IsZuaClosure: bool = (kind == .with_capture or kind == .with_zua_and_capture);
        pub const __ZuaFnTypeInfo = function_info;
        pub const __ZuaFnReturnType = ActualReturnType;
        // The initial capture value — only meaningful when __IsZuaClosure is true.
        initial: CaptureType = undefined,

        pub fn trampoline() lua.CFunction {
            return struct {
                fn luaCFunction(state_: ?*lua.State) callconv(.c) c_int {
                    const state = state_ orelse unreachable;
                    const vm = State.fromState(state) orelse {
                        lua.pushString(state, "failed to retrieve Zua context");
                        return lua.raiseError(state);
                    };

                    var ctx = Context.init(vm);

                    execute(&ctx) catch |err| {
                        const msg = ctx.err orelse formatZigError(&ctx, err);
                        lua.pushString(state, msg);
                        ctx.deinit();
                        return lua.raiseError(state);
                    };

                    ctx.deinit();
                    return @intCast(returnValueCount());
                }
            }.luaCFunction;
        }

        /// Executes the wrapped function with decoded Lua arguments and pushes
        /// its result back to the Lua stack.
        fn execute(ctx: *Context) !void {
            const args = try decodeArgs(ctx);
            const result = try callFunction(ctx, args);
            pushResult(ctx, result);
        }

        /// Decodes Lua stack arguments into the callback parameter types.
        fn decodeArgs(ctx: *Context) !Mapper.Decoder.ParseResult(decodedParameterTypes()) {
            const types = comptime decodedParameterTypes();
            const total = lua.getTop(ctx.state.luaState);
            // When VarArgs is present, parseTuple only sees the fixed-parameter
            // portion of the stack; remaining args are collected by callFunction.
            const effective_count: lua.StackCount = if (comptime hasVarArgs(function_info))
                @min(total, @as(lua.StackCount, @intCast(decodedParameterCount())))
            else
                total;
            return Mapper.Decoder.parseTuple(ctx, 1, effective_count, types) catch |err| {
                std.debug.print("{s}, {d}\n", .{ @typeName(@TypeOf(function)), effective_count });
                std.debug.print("argument decoding failed: {s}\n", .{ctx.err orelse @errorName(err)});
                setParseError(ctx);
                return error.Failed;
            };
        }

        /// Records a parse failure on `ctx.err` using a configured hook,
        /// format string, or fallback message.
        fn setParseError(ctx: *Context) void {
            const first_type = lua.valueType(ctx.state.luaState, 1);
            const fallback = "no error message provided";

            if (error_config.parse_err_hook) |hook| {
                hook(ctx, first_type, 1, fallback);
                if (ctx.err) return;
                ctx.err = fallback;
                return;
            }

            ctx.err = std.fmt.allocPrint(ctx.arena(), error_config.parse_err_fmt, .{ctx.err orelse fallback}) catch fallback;
        }

        /// Calls the wrapped function with decoded arguments, injecting `ctx`,
        /// the capture pointer, and any trailing VarArgs when required.
        fn callFunction(ctx: *Context, decoded: Mapper.Decoder.ParseResult(decodedParameterTypes())) !ActualReturnType {
            const types = comptime decodedParameterTypes();
            var call_args: std.meta.ArgsTuple(FunctionType) = undefined;

            // Slot 0: optional *Context
            if (comptime kind == .with_zua or kind == .with_zua_and_capture) call_args[0] = ctx;

            // Next slot: optional *CaptureType from upvalue 1
            if (comptime kind == .with_capture or kind == .with_zua_and_capture) {
                const capture_slot: usize = if (comptime kind == .with_zua_and_capture) 1 else 0;
                const raw_ptr = lua.toUserdata(ctx.state.luaState, lua.upvalueIndex(1)) orelse
                    @panic("ZuaFn closure: upvalue 1 is nil, capture state was not pushed");
                call_args[capture_slot] = @ptrCast(@alignCast(raw_ptr));
            }

            // Remaining slots: decoded Lua args
            inline for (types, 0..) |_, i| {
                const slot = comptime switch (kind) {
                    .with_zua => i + 1,
                    .pure => i,
                    .with_zua_and_capture => i + 2,
                    .with_capture => i + 1,
                };
                call_args[slot] = decoded[i];
            }

            // Last slot: VarArgs from remaining stack positions
            if (comptime hasVarArgs(function_info)) {
                const varargs_slot = function_info.params.len - 1;
                const decoded_count = decodedParameterCount();
                const total = lua.getTop(ctx.state.luaState);
                const remaining: usize = if (total > @as(lua.StackIndex, @intCast(decoded_count)))
                    @intCast(total - @as(lua.StackIndex, @intCast(decoded_count)))
                else
                    0;
                const start_index: lua.StackIndex = @intCast(decoded_count + 1);
                call_args[varargs_slot] = Mapper.Decoder.buildVarArgs(ctx, start_index, remaining) catch
                    return ctx.failTyped(ActualReturnType, "out of memory for varargs");
            }

            const raw = @call(.auto, function, call_args);
            return if (comptime isErrorUnion(ReturnType)) try raw else raw;
        }

        /// Pushes the callback result back to Lua, handling tuples as multiple
        /// return values.
        fn pushResult(ctx: *Context, result: ActualReturnType) void {
            if (comptime returnValueCount() == 0) return;

            if (comptime isTuple(ActualReturnType)) {
                inline for (result) |val| Mapper.Encoder.pushValue(ctx, val);
            } else {
                Mapper.Encoder.pushValue(ctx, result);
            }
        }

        /// Formats a Zig error using the configured hook or format string.
        /// Returns the recorded error message or the raw error name.
        fn formatZigError(ctx: *Context, err: anyerror) []const u8 {
            if (error_config.zig_err_hook) |hook| {
                hook(ctx, err);
                return ctx.err orelse @errorName(err);
            }
            return std.fmt.allocPrint(ctx.arena(), error_config.zig_err_fmt, .{@errorName(err)}) catch @errorName(err);
        }

        fn returnValueCount() usize {
            return switch (@typeInfo(ActualReturnType)) {
                .void => 0,
                .@"struct" => |info| if (info.is_tuple) info.fields.len else 1,
                else => 1,
            };
        }

        pub fn decodedParameterTypes() [decodedParameterCount()]type {
            comptime var types: [decodedParameterCount()]type = undefined;
            comptime var out: usize = 0;
            inline for (function_info.params, 0..) |param, i| {
                // Skip *Context (slot 0 for with_zua / with_zua_and_capture)
                if (comptime (kind == .with_zua or kind == .with_zua_and_capture) and i == 0) continue;
                // Skip capture *T (slot 0 for with_capture, slot 1 for with_zua_and_capture)
                if (comptime kind == .with_capture and i == 0) continue;
                if (comptime kind == .with_zua_and_capture and i == 1) continue;
                // Skip VarArgs (always last)
                if (comptime hasVarArgs(function_info) and i == function_info.params.len - 1) continue;
                types[out] = param.type orelse
                    @compileError("callback parameters must have concrete types");
                out += 1;
            }
            return types;
        }

        fn decodedParameterCount() usize {
            const base: usize = switch (kind) {
                .pure => function_info.params.len,
                .with_zua => function_info.params.len - 1,
                .with_capture => function_info.params.len - 1,
                .with_zua_and_capture => function_info.params.len - 2,
            };
            return if (comptime hasVarArgs(function_info)) base - 1 else base;
        }
    };
}

/// Returns true when the last parameter of `info` is `VarArgs`.
fn hasVarArgs(comptime info: std.builtin.Type.Fn) bool {
    if (info.params.len == 0) return false;
    const last = info.params[info.params.len - 1].type orelse return false;
    return last == Mapper.Decoder.VarArgs;
}

/// Compile-errors if `VarArgs` appears anywhere other than the last parameter.
fn validateVarArgs(comptime info: std.builtin.Type.Fn) void {
    inline for (info.params, 0..) |param, i| {
        const T = param.type orelse continue;
        if (T == Mapper.Decoder.VarArgs and i != info.params.len - 1) {
            @compileError("VarArgs must be the last parameter of the callback");
        }
    }
}

/// Validates that a callback declared with context accepts `*Context` as its first parameter. This prevents invalid wrapper generation for context-aware callbacks.
fn validateKind(comptime kind: CallbackKind, comptime info: std.builtin.Type.Fn) void {
    if ((kind == .with_zua or kind == .with_zua_and_capture) and info.params.len == 0) {
        @compileError("ZuaFn callbacks with context must accept *Context as their first parameter");
    }
    if ((kind == .with_capture or kind == .with_zua_and_capture) and captureParamIndex(info) == null) {
        @compileError("ZuaFn closure callbacks must have exactly one capture parameter (*T where T has Meta.Capture)");
    }
}

/// Returns the index of the capture parameter in the function's parameter list, or null if none.
fn captureParamIndex(comptime info: std.builtin.Type.Fn) ?usize {
    var found: ?usize = null;
    inline for (info.params, 0..) |param, i| {
        const T = param.type orelse continue;
        if (isCapturePointer(T)) {
            if (found != null) @compileError("ZuaFn closures may only have one capture parameter");
            found = i;
        }
    }
    return found;
}

/// Returns the pointee type of a capture parameter.
fn captureParamPointee(comptime info: std.builtin.Type.Fn) type {
    const idx = captureParamIndex(info) orelse
        @compileError("no capture parameter found");
    const T = info.params[idx].type orelse unreachable;
    return @typeInfo(T).pointer.child;
}

/// Returns true when `T` is `*S` and `S` has `ZUA_META` with `.capture` strategy.
fn isCapturePointer(comptime T: type) bool {
    if (@typeInfo(T) != .pointer) return false;
    const ptr = @typeInfo(T).pointer;
    if (ptr.size != .one) return false;
    const Child = ptr.child;
    if (!(@typeInfo(Child) == .@"struct" or @typeInfo(Child) == .@"union" or @typeInfo(Child) == .@"enum")) return false;
    if (!@hasDecl(Child, "ZUA_META")) return false;
    return Child.ZUA_META.strategy == .capture;
}

/// Validates that the capture parameter is in the correct position:
/// - first parameter if no context, or
/// - second parameter if context is first.
fn validateCapturePosition(comptime info: std.builtin.Type.Fn) void {
    const idx = captureParamIndex(info) orelse
        @compileError("ZuaFn.newClosure: function has no capture parameter (add *T where T has Meta.Capture)");

    const has_context = info.params.len > 0 and
        info.params[0].type != null and
        info.params[0].type.? == @import("../state/context.zig");

    const expected: usize = if (has_context) 1 else 0;
    if (idx != expected) {
        @compileError("ZuaFn.newClosure: capture parameter must be the first parameter " ++
            "(or the second if *Context is first)");
    }
}

/// Returns the payload type for an error union or the original type if the input is not an error union.
pub fn unwrapErrorUnion(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        else => T,
    };
}

/// Returns true when `T` is an error union type.
fn isErrorUnion(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

/// Returns true when `T` is a tuple struct type.
fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
}
