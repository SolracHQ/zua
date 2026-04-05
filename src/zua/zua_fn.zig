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
    /// parse_error is a static error message used when Lua argument decoding fails.
    parse_error: []const u8 = "invalid arguments",
    /// zig_err_fmt is a format string used to format Zig errors returned from the wrapped function.
    /// It receives the Zig error name as a single `{s}` argument.
    zig_err_fmt: ?[]const u8 = "Zig error: {s}",
    /// zig_err_hook takes precedence over zig_err_fmt if both are provided
    ///
    /// result should be an allocator-owned string describing the error
    /// Zua will free the string after pushing it to Lua
    zig_err_hook: ?fn (*Zua, anyerror) []const u8 = null,
    /// parse_err_hook is called when argument decoding fails
    /// Takes precedence over parse_error if provided
    ///
    /// result should be an allocator-owned string describing the error
    /// Zua will free the string after pushing it to Lua
    parse_err_hook: ?fn (*Zua, []const lua.Type, lua.StackIndex) anyerror![]const u8 = null,
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
                    var result = execute(vm);

                    if (result.failure) |failure| {
                        switch (failure) {
                            .static_message => |message| lua.pushString(state, message),
                            .owned_message => |message| {
                                lua.pushString(state, message);
                                vm.allocator.free(message);
                            },
                            .zig_error => |err| {
                                if (error_config.zig_err_hook) |hook| {
                                    const message = hook(vm, err) catch {
                                        lua.pushString(state, @errorName(err));
                                        return lua.raiseError(state);
                                    };
                                    lua.pushString(state, message);
                                    vm.allocator.free(message);
                                } else if (error_config.zig_err_fmt) |fmt| {
                                    const message = std.fmt.allocPrint(vm.allocator, fmt, .{@errorName(err)}) catch {
                                        lua.pushString(state, @errorName(err));
                                        return lua.raiseError(state);
                                    };
                                    lua.pushString(state, message);
                                    vm.allocator.free(message);
                                } else {
                                    lua.pushString(state, @errorName(err));
                                }
                            },
                        }
                        return lua.raiseError(state);
                    }

                    defer result.deinit(vm);
                    result.pushValues(vm);

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
                        if (error_config.parse_err_hook) |hook| {
                            const message = hook(vm, &decoded_types, 1) catch {
                                return CallbackResultType.errStatic(error_config.parse_error);
                            };
                            return CallbackResultType.errOwned(message);
                        }
                        return CallbackResultType.errStatic(error_config.parse_error);
                    };
                    defer translation.cleanupDecodedValues(vm, decoded_types, decoded_values);

                    var call_args: std.meta.ArgsTuple(FunctionType) = undefined;

                    if (comptime kind == .with_zua) {
                        call_args[0] = vm;
                    }

                    inline for (decoded_types, 0..) |_, index| {
                        const call_index = if (comptime kind == .with_zua) index + 1 else index;
                        call_args[call_index] = decoded_values[index];
                    }

                    const raw_result = @call(.auto, function, call_args);

                    return if (comptime isErrorUnionType(ReturnType))
                        raw_result catch |err| CallbackResultType.errZig(err)
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
