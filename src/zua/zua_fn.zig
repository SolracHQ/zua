const std = @import("std");
const lua = @import("../lua/lua.zig");
const translation = @import("translation.zig");
const Zua = @import("zua.zig").Zua;

const CallbackKind = enum {
    with_zua,
    pure,
};

/// Configuration for `ZuaFn.from` and `ZuaFn.pure` error handling.
pub const ZuaFnErrorConfig = struct {
    /// Format string for argument decoding failures.
    /// If both fmt and hook are null, uses "invalid arguments" as fallback.
    parse_err_fmt: ?[]const u8 = null,

    /// Hook called when argument decoding fails.
    /// Takes precedence over parse_err_fmt if both are set.
    /// Receives:
    ///   - z: allocator context
    ///   - actual_lua_type: the Lua type at the failed position
    ///   - failed_index: stack index where parse failed
    ///   - error_message: error message from Result failure (if any)
    /// Returns an allocator-owned error message string; trampoline frees it.
    parse_err_hook: ?fn (
        *Zua,
        actual_lua_type: lua.Type,
        failed_index: lua.StackIndex,
        error_message: []const u8,
    ) []const u8 = null,

    /// Format string for Zig errors.
    /// Receives error name as `{s}` placeholder.
    zig_err_fmt: ?[]const u8 = "Zig error: {s}",

    /// Hook called when wrapped function raises Zig error.
    /// Takes precedence over zig_err_fmt if both are set.
    /// Returns an allocator-owned error message string; trampoline frees it.
    zig_err_hook: ?fn (*Zua, anyerror) []const u8 = null,
};

/// Wraps a Zig function callback that receives `*Zua` as the first parameter.
///
/// The returned wrapper exposes a `.trampoline` function that can be registered
/// with Lua via `Table.setFn`.
pub fn from(comptime function: anytype, comptime error_config: ZuaFnErrorConfig) ZuaFn(function, .with_zua, error_config) {
    return .{};
}

/// Wraps a Zig function callback that does not receive `*Zua`.
///
/// The returned wrapper exposes a `.trampoline` function that can be registered
/// with Lua via `Table.setFn`.
pub fn pure(comptime function: anytype, comptime error_config: ZuaFnErrorConfig) ZuaFn(function, .pure, error_config) {
    return .{};
}

fn ZuaFn(comptime function: anytype, comptime kind: CallbackKind, comptime error_config: ZuaFnErrorConfig) type {
    const FunctionType = @TypeOf(function);
    const function_info = @typeInfo(FunctionType).@"fn";
    const ReturnType = function_info.return_type orelse @compileError("callback must have a return type");
    const CallbackResultType = unwrapCallbackResultType(ReturnType);

    validateResultType(CallbackResultType);

    return struct {
        /// Marker field to allow detection of ZuaFn types at compile time.
        pub const __IsZuaFn = true;

        /// Returns the C-compatible Lua trampoline function for this callback.
        ///
        /// The trampoline decodes Lua arguments, calls the wrapped Zig function,
        /// and pushes the callback result back onto the Lua stack.
        pub fn trampoline() lua.CFunction {
            validateSignature();

            return struct {
                fn trampoline(state_: ?*lua.State) callconv(.c) c_int {
                    const state = state_ orelse unreachable;
                    const vm = Zua.fromState(state);
                    if (vm == null) {
                        lua.pushString(state, "failed to retrieve Zua context");
                        return lua.raiseError(state);
                    }
                    var result = execute(vm.?);

                    if (result.failure) |failure| {
                        switch (failure) {
                            .static_message => |message| lua.pushString(state, message),
                            .owned_message => |message| {
                                lua.pushString(state, message);
                                vm.?.allocator.free(message);
                            },
                        }
                        return lua.raiseError(state);
                    }

                    defer result.deinit(vm.?);
                    result.pushValues(vm.?);

                    return @intCast(CallbackResultType.value_count);
                }

                fn execute(vm: *Zua) CallbackResultType {
                    const decoded_types = comptime decodedParameterTypes();
                    const decoded_values = translation.parseTuple(
                        vm,
                        1,
                        lua.getTop(vm.state),
                        decoded_types,
                        .borrowed,
                    ) catch {
                        const first_arg_type = lua.valueType(vm.state, 1);
                        const default_msg = "invalid arguments";

                        if (error_config.parse_err_hook) |hook| {
                            const message = hook(vm, first_arg_type, 1, default_msg);
                            return CallbackResultType.errOwnedString(message);
                        }

                        if (error_config.parse_err_fmt) |fmt| {
                            const message = std.fmt.allocPrint(vm.allocator, fmt, .{default_msg}) catch {
                                return CallbackResultType.errStatic(default_msg);
                            };
                            return CallbackResultType.errOwnedString(message);
                        }

                        return CallbackResultType.errStatic(default_msg);
                    };

                    // Check if Result contains a failure message
                    if (decoded_values.failure) |failure| {
                        const error_msg = switch (failure) {
                            .static_message => |msg| msg,
                            .owned_message => |msg| msg,
                        };

                        const first_arg_type = lua.valueType(vm.state, 1);

                        if (error_config.parse_err_hook) |hook| {
                            const message = hook(vm, first_arg_type, 1, error_msg);
                            return CallbackResultType.errOwnedString(message);
                        }

                        if (error_config.parse_err_fmt) |fmt| {
                            const message = std.fmt.allocPrint(vm.allocator, fmt, .{error_msg}) catch {
                                return CallbackResultType.errStatic(error_msg);
                            };
                            return CallbackResultType.errOwnedString(message);
                        }

                        return CallbackResultType.errStatic(error_msg);
                    }

                    defer translation.cleanupDecodedValues(vm, decoded_types, decoded_values.unwrap());

                    var call_args: std.meta.ArgsTuple(FunctionType) = undefined;

                    if (comptime kind == .with_zua) {
                        call_args[0] = vm;
                    }

                    inline for (decoded_types, 0..) |_, index| {
                        const call_index = if (comptime kind == .with_zua) index + 1 else index;
                        call_args[call_index] = decoded_values.unwrap()[index];
                    }

                    const raw_result = @call(.auto, function, call_args);

                    return if (comptime isErrorUnionType(ReturnType))
                        raw_result catch CallbackResultType.errStatic("error in callback")
                    else
                        raw_result;
                }
            }.trampoline;
        }

        fn validateSignature() void {
            if (comptime kind == .with_zua) {
                if (function_info.params.len == 0) {
                    @compileError("ZuaFn.from callbacks must accept *Vm as the first parameter");
                }

                const first_param = function_info.params[0].type orelse
                    @compileError("callback parameters must have concrete types");

                if (first_param != *Zua) {
                    @compileError("ZuaFn.from callbacks must accept *Vm as the first parameter");
                }
            }
        }

        fn decodedParameterTypes() [decodedParameterCount()]type {
            comptime var types: [decodedParameterCount()]type = undefined;
            comptime var out_index: usize = 0;

            inline for (function_info.params, 0..) |param, index| {
                if (comptime kind == .with_zua and index == 0) continue;
                types[out_index] = param.type orelse @compileError("callback parameters must have concrete types");
                out_index += 1;
            }

            return types;
        }

        fn decodedParameterCount() usize {
            return switch (kind) {
                .with_zua => if (function_info.params.len == 0)
                    @compileError("ZuaFn.from callbacks must accept *Vm as the first parameter")
                else
                    function_info.params.len - 1,
                .pure => function_info.params.len,
            };
        }
    };
}

fn unwrapCallbackResultType(comptime ReturnType: type) type {
    return switch (@typeInfo(ReturnType)) {
        .error_union => |info| info.payload,
        else => ReturnType,
    };
}

fn isErrorUnionType(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

fn validateResultType(comptime CallbackResultType: type) void {
    if (!@hasDecl(CallbackResultType, "value_types") or !@hasDecl(CallbackResultType, "value_count")) {
        @compileError("callback must return zua.Result(T), zua.Result(.{ ... }), or an error union containing one of them");
    }
}
