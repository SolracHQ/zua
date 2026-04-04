const std = @import("std");
const lua = @import("lua.zig");
const translation = @import("translation.zig");

const CallbackKind = enum {
    with_zua,
    pure,
};

/// Wraps a Zig function callback that receives `*Vm` as the first parameter.
///
/// The returned wrapper exposes a `.trampoline` function that can be registered
/// with Lua via `Table.setFn`.
pub fn from(comptime function: anytype, comptime parse_error: []const u8) Wrapped(function, .with_zua, parse_error) {
    return .{};
}

/// Wraps a Zig function callback that does not receive `*Vm`.
///
/// The returned wrapper exposes a `.trampoline` function that can be registered
/// with Lua via `Table.setFn`.
pub fn pure(comptime function: anytype, comptime parse_error: []const u8) Wrapped(function, .pure, parse_error) {
    return .{};
}

fn Wrapped(comptime function: anytype, comptime kind: CallbackKind, comptime parse_error: []const u8) type {
    const FunctionType = @TypeOf(function);
    const function_info = @typeInfo(FunctionType).@"fn";
    const ReturnType = function_info.return_type orelse @compileError("callback must have a return type");
    const CallbackResultType = unwrapCallbackResultType(ReturnType);

    validateResultType(CallbackResultType);

    return struct {
        /// Returns the C-compatible Lua trampoline function for this callback.
        ///
        /// The trampoline decodes Lua arguments, calls the wrapped Zig function,
        /// and pushes the callback result back onto the Lua stack.
        pub fn trampoline(comptime VmType: type, comptime TableType: type) lua.CFunction {
            validateSignature(VmType);

            return struct {
                fn trampoline(state_: ?*lua.State) callconv(.c) c_int {
                    const state = state_ orelse unreachable;
                    const vm = VmType.fromState(state);
                    var result = execute(VmType, TableType, vm, state);

                    if (result.failure) |failure| {
                        switch (failure) {
                            .static_message => |message| lua.pushString(state, message),
                            .owned_message => |message| {
                                lua.pushString(state, message);
                                vm.allocator.free(message);
                            },
                            .zig_error => |err| lua.pushString(state, @errorName(err)),
                        }
                        return lua.raiseError(state);
                    }

                    defer result.deinit(vm.allocator);
                    result.pushValues(state, vm.allocator);

                    return @intCast(CallbackResultType.value_count);
                }

                fn execute(comptime VmType_: type, comptime TableType_: type, vm: *VmType_, state: *lua.State) CallbackResultType {
                    const decoded_types = comptime decodedParameterTypes();
                    const decoded_values = translation.parseTuple(
                        TableType_,
                        state,
                        vm.allocator,
                        1,
                        lua.getTop(state),
                        decoded_types,
                        .borrowed,
                    ) catch return CallbackResultType.errStatic(parse_error);

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

        fn validateSignature(comptime VmType: type) void {
            if (comptime kind == .with_zua) {
                if (function_info.params.len == 0) {
                    @compileError("ZuaFn.from callbacks must accept *Vm as the first parameter");
                }

                const first_param = function_info.params[0].type orelse
                    @compileError("callback parameters must have concrete types");

                if (first_param != *VmType) {
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
