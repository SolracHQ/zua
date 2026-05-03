//! Trampoline implementation for converting Zig callbacks into Lua C functions.
//!
//! This module contains the internal wrapper generator used by `zua.Native`.
//! It decodes Lua arguments, invokes the Zig callback, and pushes return
//! values back to Lua while converting failures into Lua errors.
const std = @import("std");
pub const lua = @import("../../lua/lua.zig");
const Mapper = @import("../mapper/mapper.zig");
const helpers = @import("../meta/helpers.zig");
const State = @import("../state/state.zig");
const Context = @import("../state/context.zig");

/// Runtime wrapper kind that describes whether the callback accepts
/// a `*Context` and/or a capture parameter.
pub const ArgsConfig = struct {
    hasContext: bool = false,
    hasCapture: bool = false,

    // Derived slot offsets, computed once and used everywhere instead of
    // repeating the same hasContext/hasCapture branching in three places.
    /// Returns the number of prefix slots consumed by context and capture
    /// parameters before the decoded Lua arguments begin.
    ///
    /// For example, when both context and capture are present, the offset is 2
    /// and the first decoded Lua argument starts at index 2 in the call tuple.
    pub fn stackOffset(comptime self: ArgsConfig) usize {
        return @intFromBool(self.hasContext) + @intFromBool(self.hasCapture);
    }

    /// Returns the tuple slot index of the capture parameter.
    ///
    /// Slot 0 when context is absent, slot 1 when context is present. Callers
    /// use this to position the capture pointer correctly in the call tuple.
    pub fn captureSlot(comptime self: ArgsConfig) usize {
        return @intFromBool(self.hasContext);
    }
};

/// Error handling configuration for generated Lua wrapper callbacks.
///
/// Hooks and format strings are used when argument decoding fails or when the
/// wrapped Zig callback raises an error.
pub const ErrorConfig = struct {
    /// Format string used when argument decoding fails.
    parse_err_fmt: []const u8 = "argument decoding failed with error: {s}",

    /// Optional hook called on parse failure.
    ///
    /// If the hook sets `ctx.err`, its value is used directly. Otherwise the
    /// fallback format string is applied.
    parse_err_hook: ?fn (
        *Context,
        actual_lua_type: lua.Type,
        failed_index: lua.StackIndex,
        error_message: []const u8,
    ) void = null,

    /// Format string used when the callback raises a Zig error.
    /// Receives `ctx.err` if set, otherwise the raw error name as `{s}`.
    zig_err_fmt: []const u8 = "Function execution failed with error: {s}",

    /// Optional hook called when a Zig error is raised.
    ///
    /// If the hook sets `ctx.err`, that message is returned; otherwise the
    /// raw error name is used.
    zig_err_hook: ?fn (*Context, anyerror) void = null,
};

/// Documentation metadata for one exposed function parameter.
pub const ArgInfo = struct {
    name: []const u8,
    description: ?[]const u8 = null,
};

/// Documentation options for a native wrapper.
///
/// Passed as a comptime struct to `trampoline.make` to attach static metadata
/// used by the docs generator.
pub const DocOptions = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    args: []const ArgInfo = &.{},
};

/// Creates a concrete wrapper type for a Zig callback and error handling config.
///
/// The returned type exposes `trampoline()` for use as a Lua C function and
/// handles argument decoding, function invocation, return value encoding, and
/// Lua error raising.
///
/// Arguments:
/// - `function`: the Zig callback to wrap. Must have an explicit return type.
/// - `kind`: describes whether the callback receives `*Context` and/or a capture pointer.
/// - `error_config`: format strings and optional hooks for parse and Zig error reporting.
/// - `doc`: optional documentation metadata for stub generation.
///
/// Returns:
/// - `type`: a struct type with `trampoline()` and metadata fields
///   (`name`, `description`, `args`). For closures, also carries an `initial` capture field.
///
/// Example:
/// ```zig
/// const T = trampoline.make(myFn, .{ .hasContext = true }, .{}, .{
///     .args = &.{
///         .{ .name = "address", .description = "Memory address to read" },
///     },
/// });
/// globals.set(&ctx, "read", T{});
/// ```
pub fn make(
    comptime function: anytype,
    comptime kind: ArgsConfig,
    comptime error_config: ErrorConfig,
    comptime doc: DocOptions,
) type {
    const FunctionType = @TypeOf(function);
    const function_info = @typeInfo(FunctionType).@"fn";
    const ReturnType = function_info.return_type orelse
        @compileError("Zig native functions must have an explicit return type (use void if none)");
    const ActualReturnType = helpers.unwrapErrorUnion(ReturnType);

    comptime validateKind(kind, function_info);
    comptime validateVarArgs(function_info);

    const CaptureType: type = if (comptime kind.hasCapture)
        captureParamPointee(function_info)
    else
        void;

    return struct {
        /// Marker used by zua internals to identify wrapper types.
        pub const __IsZuaNativeFunction = true;

        /// Indicates whether this wrapper carries a capture value.
        pub const __IsZuaClosure: bool = kind.hasCapture;

        /// Raw Zig function type info for the wrapped callback.
        pub const __ZuaFnTypeInfo = function_info;

        /// The normalized return type of the wrapped callback, with error unions unwrapped.
        pub const __ZuaNativeReturnType = ActualReturnType;

        /// The display name of the wrapped function, used for docs and debugging.
        name: []const u8 = doc.name orelse @typeName(FunctionType),

        /// Optional documentation string for the wrapped function.
        description: []const u8 = doc.description orelse "",

        /// Parameter metadata used only for documentation generation.
        args: []const ArgInfo = doc.args,

        /// For closures, the initial capture value to bundle with the callback.
        initial: CaptureType = undefined,

        /// Returns the raw Lua C function pointer for this wrapper.
        ///
        /// The returned function pointer is suitable for passing directly to
        /// `lua_pushcfunction` or any zua registration helper. Each call returns
        /// the same stateless function pointer; the wrapper type carries no
        /// runtime state (capture state lives in upvalue 1 for closures).
        ///
        /// Use this when you need the raw `CFunction` rather than pushing the
        /// wrapper value through the encoder.
        ///
        /// Example:
        /// ```zig
        /// const fn_ptr = zua.Native.NativeFn(add, .{}, .{}).trampoline();
        /// lua.pushCFunction(state, fn_ptr);
        /// ```
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

        fn execute(ctx: *Context) !void {
            const args = try decodeArgs(ctx);
            const result = try callFunction(ctx, args);
            try pushResult(ctx, result);
        }

        fn decodeArgs(ctx: *Context) !Mapper.Decoder.ParseResult(decodedParameterTypes()) {
            const types = comptime decodedParameterTypes();
            const total = lua.getTop(ctx.state.luaState);
            const effective_count: lua.StackCount = if (comptime hasVarArgs(function_info))
                @min(total, @as(lua.StackCount, @intCast(decodedParameterCount())))
            else
                total;
            return Mapper.Decoder.parseTuple(ctx, 1, effective_count, types) catch {
                setParseError(ctx);
                return error.Failed;
            };
        }

        fn setParseError(ctx: *Context) void {
            const first_type = lua.valueType(ctx.state.luaState, 1);
            const fallback = "no error message provided";

            if (error_config.parse_err_hook) |hook| {
                hook(ctx, first_type, 1, fallback);
                if (ctx.err) return;
                ctx.err = fallback;
                return;
            }

            ctx.err = std.fmt.allocPrint(
                ctx.arena(),
                error_config.parse_err_fmt,
                .{ctx.err orelse fallback},
            ) catch fallback;
        }

        fn callFunction(
            ctx: *Context,
            decoded: Mapper.Decoder.ParseResult(decodedParameterTypes()),
        ) !ActualReturnType {
            const types = comptime decodedParameterTypes();
            var call_args: std.meta.ArgsTuple(FunctionType) = undefined;

            if (comptime kind.hasContext) call_args[0] = ctx;

            if (comptime kind.hasCapture) {
                const raw_ptr = lua.toUserdata(ctx.state.luaState, lua.upvalueIndex(1)) orelse
                    @panic("closure upvalue 1 is nil, capture was not pushed");
                call_args[comptime kind.captureSlot()] = @ptrCast(@alignCast(raw_ptr));
            }

            inline for (types, 0..) |_, i| {
                call_args[comptime kind.stackOffset() + i] = decoded[i];
            }

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
            return             if (comptime helpers.isErrorUnion(ReturnType)) try raw else raw;
        }

        fn pushResult(ctx: *Context, result: ActualReturnType) !void {
            if (comptime returnValueCount() == 0) return;

            if (comptime helpers.isTuple(ActualReturnType)) {
                inline for (result) |val| try Mapper.Encoder.pushValue(ctx, val);
            } else {
                try Mapper.Encoder.pushValue(ctx, result);
            }
        }

        fn formatZigError(ctx: *Context, err: anyerror) []const u8 {
            if (error_config.zig_err_hook) |hook| {
                hook(ctx, err);
                return ctx.err orelse @errorName(err);
            }
            return std.fmt.allocPrint(
                ctx.arena(),
                error_config.zig_err_fmt,
                .{@errorName(err)},
            ) catch @errorName(err);
        }

        fn returnValueCount() usize {
            return switch (@typeInfo(ActualReturnType)) {
                .void => 0,
                .@"struct" => |info| if (info.is_tuple) info.fields.len else 1,
                else => 1,
            };
        }

        /// Returns an array of decoded parameter types, excluding context,
        /// capture, and varargs parameters.
        ///
        /// The array length matches `decodedParameterCount()` and the types are
        /// derived from the original function signature minus the special
        /// parameters. Used by `decodeArgs` to drive the decoder.
        pub fn decodedParameterTypes() [decodedParameterCount()]type {
            comptime var types: [decodedParameterCount()]type = undefined;
            comptime var out: usize = 0;
            inline for (function_info.params, 0..) |param, i| {
                if (comptime kind.hasContext and i == 0) continue;
                if (comptime kind.hasCapture and i == kind.captureSlot()) continue;
                if (comptime hasVarArgs(function_info) and i == function_info.params.len - 1) continue;
                types[out] = param.type orelse
                    @compileError(std.fmt.comptimePrint("parameter #{d} has no type", .{i}));
                out += 1;
            }
            return types;
        }

        fn decodedParameterCount() usize {
            const base: usize = function_info.params.len - kind.stackOffset();
            return if (comptime hasVarArgs(function_info)) base - 1 else base;
        }

        // I really don't know if this works but as soon as I can see errors better, right?
        test {
            std.testing.refAllDecls(@This());
        }
    };
}

fn hasVarArgs(comptime info: std.builtin.Type.Fn) bool {
    if (info.params.len == 0) return false;
    const last = info.params[info.params.len - 1].type orelse return false;
    return last == Mapper.Decoder.VarArgs;
}

fn validateVarArgs(comptime info: std.builtin.Type.Fn) void {
    inline for (info.params, 0..) |param, i| {
        const T = param.type orelse continue;
        if (T == Mapper.Decoder.VarArgs and i != info.params.len - 1) {
            @compileError(std.fmt.comptimePrint("VarArgs must be the last parameter of the zig native function, found at position #{d}", .{i}));
        }
    }
}

fn validateKind(comptime kind: ArgsConfig, comptime info: std.builtin.Type.Fn) void {
    if (kind.hasContext and info.params.len == 0) {
        @compileError("Zig native function with context must have at least one parameter for the context if declared as requiring context");
    }
    if (kind.hasCapture and captureParamIndex(info) == null) {
        @compileError("Closure zig native function must have a capture parameter (a pointer to a struct/union/enum with Meta.Capture)");
    }
}

fn captureParamIndex(comptime info: std.builtin.Type.Fn) ?usize {
    var found: ?usize = null;
    inline for (info.params, 0..) |param, i| {
        const T = param.type orelse continue;
        if (helpers.isCapturePointer(T)) {
            if (found != null) @compileError(std.fmt.comptimePrint("Closure zig native function cannot have more than one capture parameter, found at positions #{d} and #{d}", .{ found.?, i }));
            found = i;
        }
    }
    return found;
}

fn captureParamPointee(comptime info: std.builtin.Type.Fn) type {
    const idx = captureParamIndex(info) orelse
        @compileError("Closure zig native function must have a capture parameter (a pointer to a struct/union/enum with Meta.Capture)");
    const T = info.params[idx].type orelse unreachable;
    return @typeInfo(T).pointer.child;
}



/// Ensures a closure callback has its capture parameter in the expected slot.
///
/// The capture must be the first argument when no `*Context` is present, or
/// the second argument when `*Context` comes first.
pub fn validateCapturePosition(comptime info: std.builtin.Type.Fn) void {
    const idx = captureParamIndex(info) orelse
        @compileError("Closure zig native function must have a capture parameter (a pointer to a struct/union/enum with Meta.Capture)");

    const has_context = info.params.len > 0 and
        info.params[0].type != null and
        info.params[0].type.? == Context;

    const expected: usize = if (has_context) 1 else 0;
    if (idx != expected) {
        @compileError("Closure zig native function: capture parameter must be first, or second when *Context is first");
    }
}



test {
    std.testing.refAllDecls(@This());
}
