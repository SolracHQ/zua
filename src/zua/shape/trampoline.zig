//! Generates the Lua CFunction trampolines that bridge Zig functions
//! and closures into callable Lua values. Each trampoline is a compiled
//! C closure that decodes arguments from the Lua stack, calls back into
//! Zig, and pushes return values. Used by `Shape.Fn` and `Shape.Closure`.

const std = @import("std");
pub const lua = @import("../../lua/lua.zig");
const Mapper = @import("../mapper/api.zig");
const Decoder = @import("../mapper/decode/decoder.zig");
const Tracing = @import("../mapper/decode/tracing.zig");
const Introspect = @import("../introspect.zig");
const State = @import("../state.zig");
const Context = @import("../context.zig");
const Marker = @import("../marker.zig");

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
    /// The hook receives the formatted path and error message. Can override
    /// by setting `ctx.err`. If unset, the default path-formatting is used.
    parse_err_hook: ?fn (*Context, *const Tracing.Trace) void = null,
};

/// Builds a callable wrapper type for a Zig function. The returned type
/// carries a `trampoline()` method that produces the Lua CFunction closure.
/// Arguments are decoded from the Lua stack based on the function signature.
pub fn makeFn(comptime function: anytype, comptime hasContext: bool, comptime options: FnOptions) type {
    const FunctionType = @TypeOf(function);
    const function_info = @typeInfo(FunctionType).@"fn";
    const ReturnType = function_info.return_type orelse
        @compileError("Zig native functions must have an explicit return type (use void if none)");
    const ActualReturnType = Introspect.unwrapErrorUnion(ReturnType);

    comptime validateKind(hasContext, function_info);
    comptime validateVarArgs(function_info);

    return struct {
        pub const __ZUA_MARKER: std.EnumSet(Marker.Marker) = Marker.new(&.{.native_function});

        const __ZuaFnTypeInfo = function_info;
        const __ZuaNativeReturnType = ActualReturnType;

        pub const description: []const u8 = options.description;
        pub const args: []const ArgInfo = options.args;
        pub const parse_err_hook: ?fn (*Context, *const Tracing.Trace) void = options.parse_err_hook;
        const decode_depth = Tracing.maxDecodeDepth(decodedParameterTypes());

        pub fn trampoline() lua.CFunction {
            return struct {
                fn luaCFunction(state_: ?*lua.State) callconv(.c) c_int {
                    const state = state_ orelse unreachable;
                    const vm = State.fromState(state) orelse {
                        lua.pushString(state, "failed to retrieve Zua context");
                        return lua.raiseError(state);
                    };

                    var ctx = Context.init(vm);
                    var segs: [decode_depth]Tracing.Segment = @splat(.empty);
                    var decode_err: Tracing.DecodeError = .{ .tag = .custom };
                    const trace = Tracing.Trace{ .path = &segs, .deep = 0, .err = &decode_err };

                    execute(&ctx, trace) catch |err| {
                        const msg = ctx.err orelse @errorName(err);
                        lua.pushString(state, msg);
                        ctx.deinit();
                        return lua.raiseError(state);
                    };

                    ctx.deinit();
                    return @intCast(returnValueCountFor(ActualReturnType));
                }
            }.luaCFunction;
        }

        fn execute(ctx: *Context, trace: Tracing.Trace) !void {
            const decoded = try decodeArgs(ctx, trace);
            const result = try callFunction(ctx, decoded);
            try pushResult(ctx, result);
        }

        fn decodeArgs(ctx: *Context, trace: Tracing.Trace) !Decoder.ParseResult(decodedParameterTypes()) {
            const types = comptime decodedParameterTypes();
            const total = lua.getTop(ctx.state.luaState);
            const effective_count: lua.StackCount = if (comptime hasVarArgs(function_info))
                @min(total, @as(lua.StackCount, @intCast(decodedParameterCount())))
            else
                total;
            return Decoder.parseArgsDepth(ctx, 1, effective_count, types, trace) catch {
                if (parse_err_hook) |hook| {
                    hook(ctx, &trace);
                } else {
                    const fmt = Tracing.formatDecodePathArg(ctx.arena(), trace.path, args) catch "";
                    const err_msg = trace.err.format(ctx.arena()) catch "decode failed";
                    ctx.err = if (fmt.len > 0)
                        std.fmt.allocPrint(ctx.arena(), "{s}: {s}", .{ fmt, err_msg }) catch err_msg
                    else
                        err_msg;
                }
                return error.Failed;
            };
        }

        fn callFunction(
            ctx: *Context,
            decoded: Decoder.ParseResult(decodedParameterTypes()),
        ) !ActualReturnType {
            const types = comptime decodedParameterTypes();
            var call_args: std.meta.ArgsTuple(FunctionType) = undefined;

            if (comptime hasContext) call_args[0] = ctx;

            inline for (types, 0..) |_, i| {
                call_args[comptime stackOffset() + i] = decoded[i];
            }

            if (comptime hasVarArgs(function_info)) {
                const varargs_slot = function_info.params.len - 1;
                call_args[varargs_slot] = try buildVarArgsFor(ctx, function_info, decodedParameterCount());
            }

            const raw = @call(.auto, function, call_args);
            return if (comptime Introspect.isErrorUnion(ReturnType)) try raw else raw;
        }

        fn pushResult(ctx: *Context, result: ActualReturnType) !void {
            try pushResultFor(ctx, result, ActualReturnType);
        }

        pub fn decodedParameterTypes() [decodedParameterCount()]type {
            comptime var types: [decodedParameterCount()]type = undefined;
            comptime var out: usize = 0;
            inline for (function_info.params, 0..) |param, i| {
                if (comptime hasContext and i == 0) continue;
                if (comptime hasVarArgs(function_info) and i == function_info.params.len - 1) continue;
                types[out] = param.type orelse
                    @compileError(std.fmt.comptimePrint("parameter #{d} has no type", .{i}));
                out += 1;
            }
            return types;
        }

        fn decodedParameterCount() usize {
            const base: usize = function_info.params.len - stackOffset();
            return if (comptime hasVarArgs(function_info)) base - 1 else base;
        }

        fn stackOffset() usize {
            return @intFromBool(hasContext);
        }
    };
}

/// Builds a callable wrapper type for a closure. The struct `T` is stored
/// as upvalue 1 in the Lua C closure and recovered on each call. Optional
/// `__gc` cleanup is wired through the metatable.
pub fn makeClosure(comptime T: type, comptime callback: anytype, comptime options: FnOptions) type {
    const CallbackType = @TypeOf(callback);
    const cb_info = @typeInfo(CallbackType).@"fn";
    const ReturnType = cb_info.return_type orelse
        @compileError("Closure callback must have an explicit return type (use void if none)");
    const ActualReturnType = Introspect.unwrapErrorUnion(ReturnType);

    const has_context = comptime cb_info.params.len > 0 and
        cb_info.params[0].type != null and
        cb_info.params[0].type.? == *Context;
    const upvalue_param_index: usize = if (has_context) 1 else 0;

    comptime validateClosureCallback(T, cb_info, has_context);
    comptime validateVarArgs(cb_info);

    return struct {
        pub const __ZUA_MARKER: std.EnumSet(Marker.Marker) = Marker.new(&.{.native_function});
        pub const description: []const u8 = options.description;
        pub const args: []const ArgInfo = options.args;
        pub const parse_err_hook: ?fn (*Context, *const Tracing.Trace) void = options.parse_err_hook;
        const decode_depth = Tracing.maxDecodeDepth(decodedParameterTypes());

        const __ZuaFnTypeInfo = cb_info;
        const __ZuaNativeReturnType = ActualReturnType;

        pub fn trampoline() lua.CFunction {
            return struct {
                fn luaCFunction(state_: ?*lua.State) callconv(.c) c_int {
                    const state = state_ orelse unreachable;
                    const vm = State.fromState(state) orelse {
                        lua.pushString(state, "failed to retrieve Zua context");
                        return lua.raiseError(state);
                    };
                    var ctx = Context.init(vm);
                    var segs: [decode_depth]Tracing.Segment = @splat(.empty);
                    var decode_err: Tracing.DecodeError = .{ .tag = .custom };
                    const trace = Tracing.Trace{ .path = &segs, .deep = 0, .err = &decode_err };
                    execute(&ctx, trace) catch |err| {
                        const msg = ctx.err orelse @errorName(err);
                        lua.pushString(state, msg);
                        ctx.deinit();
                        return lua.raiseError(state);
                    };
                    ctx.deinit();
                    return @intCast(returnValueCountFor(ActualReturnType));
                }
            }.luaCFunction;
        }

        fn execute(ctx: *Context, trace: Tracing.Trace) !void {
            const decoded = try decodeArgs(ctx, trace);
            const result = try callFunction(ctx, decoded);
            try pushResult(ctx, result);
        }

        fn decodeArgs(ctx: *Context, trace: Tracing.Trace) !Decoder.ParseResult(decodedParameterTypes()) {
            const types = comptime decodedParameterTypes();
            const total = lua.getTop(ctx.state.luaState);
            const effective_count: lua.StackCount = if (comptime hasVarArgs(cb_info))
                @min(total, @as(lua.StackCount, @intCast(decodedParameterCount())))
            else
                total;
            return Decoder.parseArgsDepth(ctx, 1, effective_count, types, trace) catch {
                if (parse_err_hook) |hook| {
                    hook(ctx, &trace);
                } else {
                    const fmt = Tracing.formatDecodePathArg(ctx.arena(), trace.path, args) catch "";
                    const err_msg = trace.err.format(ctx.arena()) catch "decode failed";
                    ctx.err = if (fmt.len > 0)
                        std.fmt.allocPrint(ctx.arena(), "{s}: {s}", .{ fmt, err_msg }) catch err_msg
                    else
                        err_msg;
                }
                return error.Failed;
            };
        }

        fn callFunction(
            ctx: *Context,
            decoded: Decoder.ParseResult(decodedParameterTypes()),
        ) !ActualReturnType {
            const types = comptime decodedParameterTypes();
            var call_args: std.meta.ArgsTuple(CallbackType) = undefined;

            if (comptime has_context) call_args[0] = ctx;

            const raw_ptr = lua.toUserdata(ctx.state.luaState, lua.upvalueIndex(1)) orelse
                @panic("closure upvalue 1 is nil, capture was not pushed");
            call_args[comptime upvalue_param_index] = @ptrCast(@alignCast(raw_ptr));

            inline for (types, 0..) |_, i| {
                call_args[comptime stackOffset() + i] = decoded[i];
            }

            if (comptime hasVarArgs(cb_info)) {
                const varargs_slot = cb_info.params.len - 1;
                call_args[varargs_slot] = try buildVarArgsFor(ctx, cb_info, decodedParameterCount());
            }

            const raw = @call(.auto, callback, call_args);
            return if (comptime Introspect.isErrorUnion(ReturnType)) try raw else raw;
        }

        fn pushResult(ctx: *Context, result: ActualReturnType) !void {
            try pushResultFor(ctx, result, ActualReturnType);
        }

        pub fn decodedParameterTypes() [decodedParameterCount()]type {
            comptime var types: [decodedParameterCount()]type = undefined;
            comptime var out: usize = 0;
            inline for (cb_info.params, 0..) |param, i| {
                if (comptime has_context and i == 0) continue;
                if (comptime i == upvalue_param_index) continue;
                if (comptime hasVarArgs(cb_info) and i == cb_info.params.len - 1) continue;
                types[out] = param.type orelse
                    @compileError(std.fmt.comptimePrint("closure param #{d} has no type", .{i}));
                out += 1;
            }
            return types;
        }

        fn decodedParameterCount() usize {
            const base: usize = cb_info.params.len - stackOffset();
            return if (comptime hasVarArgs(cb_info)) base - 1 else base;
        }

        fn stackOffset() usize {
            return @intFromBool(has_context) + 1;
        }
    };
}

fn validateClosureCallback(comptime T: type, comptime info: std.builtin.Type.Fn, comptime has_context: bool) void {
    const up_index: usize = if (has_context) 1 else 0;
    if (info.params.len <= up_index) {
        @compileError("Closure callback must take *" ++ @typeName(T) ++ " as " ++ (if (has_context) "second" else "first") ++ " parameter");
    }
    const param_type = info.params[up_index].type orelse
        @compileError("Closure callback parameter at index " ++ std.fmt.comptimePrint("{d}", .{up_index}) ++ " has no type");
    const ptr_info = @typeInfo(param_type);
    if (ptr_info != .pointer or ptr_info.pointer.size != .one or ptr_info.pointer.child != T) {
        @compileError("Closure callback parameter at index " ++ std.fmt.comptimePrint("{d}", .{up_index}) ++ " must be *" ++ @typeName(T));
    }
}

fn hasVarArgs(comptime info: std.builtin.Type.Fn) bool {
    if (info.params.len == 0) return false;
    const last = info.params[info.params.len - 1].type orelse return false;
    return last == Mapper.VarArgs;
}

fn validateVarArgs(comptime info: std.builtin.Type.Fn) void {
    inline for (info.params, 0..) |param, i| {
        const T = param.type orelse continue;
        if (T == Mapper.VarArgs and i != info.params.len - 1) {
            @compileError(std.fmt.comptimePrint("VarArgs must be the last parameter of the zig native function, found at position #{d}", .{i}));
        }
    }
}

fn returnValueCountFor(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .void => 0,
        .@"struct" => |info| if (info.is_tuple) info.fields.len else 1,
        else => 1,
    };
}

fn buildVarArgsFor(
    ctx: *Context,
    comptime fn_info: std.builtin.Type.Fn,
    comptime decodedParameterCount: usize,
) !Mapper.VarArgs {
    const varargs_slot = fn_info.params.len - 1;
    _ = varargs_slot;
    const total = lua.getTop(ctx.state.luaState);
    const remaining: usize = if (total > @as(lua.StackIndex, @intCast(decodedParameterCount)))
        @intCast(total - @as(lua.StackIndex, @intCast(decodedParameterCount)))
    else
        0;
    const start_index: lua.StackIndex = @intCast(decodedParameterCount + 1);
    return Decoder.buildVarArgs(ctx, start_index, remaining) catch return error.Failed;
}

fn pushResultFor(ctx: *Context, result: anytype, comptime T: type) !void {
    if (comptime returnValueCountFor(T) == 0) return;
    if (comptime Introspect.isTuple(T)) {
        inline for (result) |val| try Mapper.Encoder.push(ctx, val);
    } else {
        try Mapper.Encoder.push(ctx, result);
    }
}

fn validateKind(comptime hasContext: bool, comptime info: std.builtin.Type.Fn) void {
    if (hasContext and info.params.len == 0) {
        @compileError("Zig native function with context must have at least one parameter for the context if declared as requiring context");
    }
}

pub fn nativeReturnType(comptime T: type) type {
    if (comptime !Marker.isNativeFunction(T)) {
        @compileError(@typeName(T) ++ " is not a NativeFn/Closure wrapper, cannot query nativeReturnType");
    }
    return T.__ZuaNativeReturnType;
}

pub fn fnTypeInfo(comptime T: type) std.builtin.Type.Fn {
    if (comptime !Marker.isNativeFunction(T)) {
        @compileError(@typeName(T) ++ " is not a NativeFn/Closure wrapper, cannot query fnTypeInfo");
    }
    return T.__ZuaFnTypeInfo;
}

test {
    std.testing.refAllDecls(@This());
}
