//! Trampoline implementation for converting Zig callbacks into Lua C functions.
//!
//! This module contains the internal wrapper generator used by `zua.Native`.
//! It decodes Lua arguments, invokes the Zig callback, and pushes return
//! values back to Lua while converting failures into Lua errors.
const std = @import("std");
pub const lua = @import("../../lua/lua.zig");
const Mapper = @import("../mapper/mapper.zig");
const Meta = @import("../meta.zig");
const State = @import("../state/state.zig");
const Context = @import("../state/context.zig");

/// Runtime wrapper kind that describes whether the callback accepts
/// a `*Context` and/or a capture parameter.
pub const ArgsConfig = struct {
    hasContext: bool = false,
    hasCapture: bool = false,

    // Derived slot offsets, computed once and used everywhere instead of
    // repeating the same hasContext/hasCapture branching in three places.
    pub fn stackOffset(comptime self: ArgsConfig) usize {
        return @intFromBool(self.hasContext) + @intFromBool(self.hasCapture);
    }

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

/// Creates a concrete wrapper type for a Zig callback and error handling config.
///
/// The returned type exposes `trampoline()` for use as a Lua C function and
/// handles argument decoding, function invocation, return value encoding, and
/// Lua error raising.
pub fn make(
    comptime function: anytype,
    comptime kind: ArgsConfig,
    comptime error_config: ErrorConfig,
) type {
    const FunctionType = @TypeOf(function);
    const function_info = @typeInfo(FunctionType).@"fn";
    const ReturnType = function_info.return_type orelse
        @compileError("callback must have a return type");
    const ActualReturnType = unwrapErrorUnion(ReturnType);

    comptime validateKind(kind, function_info);
    comptime validateVarArgs(function_info);

    const CaptureType: type = if (comptime kind.hasCapture)
        captureParamPointee(function_info)
    else
        void;

    return struct {
        pub const __IsZuaFn = true;
        pub const __IsZuaClosure: bool = kind.hasCapture;
        pub const __ZuaFnTypeInfo = function_info;
        pub const __ZuaFnReturnType = ActualReturnType;

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

        fn execute(ctx: *Context) !void {
            const args = try decodeArgs(ctx);
            const result = try callFunction(ctx, args);
            pushResult(ctx, result);
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
            return if (comptime isErrorUnion(ReturnType)) try raw else raw;
        }

        fn pushResult(ctx: *Context, result: ActualReturnType) void {
            if (comptime returnValueCount() == 0) return;

            if (comptime isTuple(ActualReturnType)) {
                inline for (result) |val| Mapper.Encoder.pushValue(ctx, val);
            } else {
                Mapper.Encoder.pushValue(ctx, result);
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

        pub fn decodedParameterTypes() [decodedParameterCount()]type {
            comptime var types: [decodedParameterCount()]type = undefined;
            comptime var out: usize = 0;
            inline for (function_info.params, 0..) |param, i| {
                if (comptime kind.hasContext and i == 0) continue;
                if (comptime kind.hasCapture and i == kind.captureSlot()) continue;
                if (comptime hasVarArgs(function_info) and i == function_info.params.len - 1) continue;
                types[out] = param.type orelse
                    @compileError("callback parameters must have concrete types");
                out += 1;
            }
            return types;
        }

        fn decodedParameterCount() usize {
            const base: usize = function_info.params.len - kind.stackOffset();
            return if (comptime hasVarArgs(function_info)) base - 1 else base;
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
            @compileError("VarArgs must be the last parameter of the callback");
        }
    }
}

fn validateKind(comptime kind: ArgsConfig, comptime info: std.builtin.Type.Fn) void {
    if (kind.hasContext and info.params.len == 0) {
        @compileError("callback with context must accept *Context as its first parameter");
    }
    if (kind.hasCapture and captureParamIndex(info) == null) {
        @compileError("closure callback must have exactly one capture parameter (*T where T has Meta.Capture)");
    }
}

fn captureParamIndex(comptime info: std.builtin.Type.Fn) ?usize {
    var found: ?usize = null;
    inline for (info.params, 0..) |param, i| {
        const T = param.type orelse continue;
        if (isCapturePointer(T)) {
            if (found != null) @compileError("closures may only have one capture parameter");
            found = i;
        }
    }
    return found;
}

fn captureParamPointee(comptime info: std.builtin.Type.Fn) type {
    const idx = captureParamIndex(info) orelse
        @compileError("no capture parameter found");
    const T = info.params[idx].type orelse unreachable;
    return @typeInfo(T).pointer.child;
}

fn isCapturePointer(comptime T: type) bool {
    if (@typeInfo(T) != .pointer) return false;
    const ptr = @typeInfo(T).pointer;
    if (ptr.size != .one) return false;
    const Child = ptr.child;
    if (!(@typeInfo(Child) == .@"struct" or @typeInfo(Child) == .@"union" or @typeInfo(Child) == .@"enum")) return false;
    if (!@hasDecl(Child, "ZUA_META")) return false;
    return Child.ZUA_META.strategy == .capture;
}

/// Ensures a closure callback has its capture parameter in the expected slot.
///
/// The capture must be the first argument when no `*Context` is present, or
/// the second argument when `*Context` comes first.
pub fn validateCapturePosition(comptime info: std.builtin.Type.Fn) void {
    const idx = captureParamIndex(info) orelse
        @compileError("Binding.closure: function has no capture parameter (add *T where T declares Meta.Capture)");

    const has_context = info.params.len > 0 and
        info.params[0].type != null and
        info.params[0].type.? == Context;

    const expected: usize = if (has_context) 1 else 0;
    if (idx != expected) {
        @compileError("Binding.closure: capture parameter must be first, or second when *Context is first");
    }
}

/// Returns the payload type of an error union, or the original type otherwise.
pub fn unwrapErrorUnion(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        else => T,
    };
}

fn isErrorUnion(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

fn isTuple(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.is_tuple,
        else => false,
    };
}
