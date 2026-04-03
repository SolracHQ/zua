//! The main Zig wrapper over Lua 5.4, built to avoid the stack discipline pain.
//!
//! Zua (from the name of this library) is the heart of the wrapper.
//! It owns the Lua state and allocator, providing ergonomic APIs for:
//! - Executing Lua code and decoding results into typed tuples
//! - Registering Zig callbacks that receive typed arguments and return typed values
//! - Building and manipulating Lua tables with absolute indexes (no -1 magic)
//! - Threading host state through the VM via `setLightUserdata` and the registry
//!
//! The key difference from the raw C API: `longjmp` (from `lua_error`) happens after
//! your callback fully returns, so `defer` cleanup always runs before the error propagates.

const std = @import("std");
const lua = @import("lua.zig");
const Args = @import("args.zig").Args;
const decode = @import("decode.zig");
const Table = @import("table.zig").Table;
const result_module = @import("result.zig");

const zua_registry_key: [:0]const u8 = "zua_zua";

pub const Result = result_module.Result;
pub const Failure = result_module.Failure;

/// The main Zua Lua wrapper: owns the state, allocator, and all callbacks.
///
/// Create one with `Zua.init(allocator)` and keep it heap-allocated so its pointer
/// remains stable inside callbacks. Call `deinit` to close the state and free memory.
///
/// Use `globals()` and `registry()` to attach tables or functions, `exec()` to run Lua code,
/// `eval()` to decode typed return values, and `tableFrom()` to convert Zig structs into tables.
pub const Zua = struct {
    allocator: std.mem.Allocator,
    state: *lua.State,

    /// Creates a heap-allocated Zua instance, opens Lua standard libraries, and stores the pointer in the registry.
    /// The returned pointer is stable and safe to capture in callbacks.
    pub fn init(allocator: std.mem.Allocator) !*Zua {
        const self = try allocator.create(Zua);
        errdefer allocator.destroy(self);

        const state = try lua.init();
        errdefer lua.deinit(state);

        self.* = .{
            .allocator = allocator,
            .state = state,
        };

        lua.openLibs(state);
        lua.pushLightUserdata(state, self);
        lua.setField(state, lua.REGISTRY_INDEX, zua_registry_key);

        return self;
    }

    /// Closes the Lua state and frees the Zua allocation.
    pub fn deinit(self: *Zua) void {
        lua.pushNil(self.state);
        lua.setField(self.state, lua.REGISTRY_INDEX, zua_registry_key);
        lua.deinit(self.state);
        self.allocator.destroy(self);
    }

    /// Pushes the Lua global table onto the stack and returns an absolute-indexed handle.
    /// Always call `defer handle.pop()` to clean up the stack afterward.
    pub fn globals(self: *Zua) Table {
        _ = lua.getIndex(self.state, lua.REGISTRY_INDEX, lua.RIDX_GLOBALS);
        return Table.fromStack(self.state, self.allocator, -1);
    }

    /// Pushes the Lua registry onto the stack and returns an absolute-indexed handle.
    /// Use this to store host state via `setLightUserdata("key", &state)`.
    pub fn registry(self: *Zua) Table {
        lua.pushValue(self.state, lua.REGISTRY_INDEX);
        return Table.fromStack(self.state, self.allocator, -1);
    }

    /// Creates a new Lua table with optional capacity hints and returns an absolute-indexed handle.
    /// Pass 0 for capacity hints if you don't know the final size; Lua will resize internally.
    pub fn createTable(self: *Zua, array_capacity: i32, record_capacity: i32) Table {
        lua.createTable(self.state, array_capacity, record_capacity);
        return Table.fromStack(self.state, self.allocator, -1);
    }

    /// Converts a Zig struct, array, tuple, or slice into a Lua table recursively.
    /// Array elements become integer keys; struct fields become string keys.
    /// Nested structs/arrays are converted recursively.
    pub fn tableFrom(self: *Zua, value: anytype) Table {
        const table = self.createTable(Table.inferArrayCapacity(value), Table.inferRecordCapacity(value));
        table.fill(value);
        return table;
    }

    /// Executes a Lua chunk and ignores any returned values.
    /// Useful for setup code or side-effect-only operations.
    pub fn exec(self: *Zua, source: []const u8) !void {
        const previous_top = lua.getTop(self.state);
        errdefer lua.setTop(self.state, previous_top);

        const chunk = try self.allocator.dupeZ(u8, source);
        defer self.allocator.free(chunk);

        try lua.loadString(self.state, chunk);
        try lua.protectedCall(self.state, 0, 0, 0);
    }

    /// Executes a Lua chunk and decodes its return values into a typed tuple.
    /// Example: `const (num, msg) = try zua.eval(.{i32, []const u8}, "return 42, 'ok'")`.
    pub fn eval(self: *Zua, comptime types: anytype, source: []const u8) (lua.Error || decode.ParseError)!decode.ParseResult(types) {
        const previous_top = lua.getTop(self.state);
        errdefer lua.setTop(self.state, previous_top);

        const chunk = try self.allocator.dupeZ(u8, source);
        defer self.allocator.free(chunk);

        try lua.loadString(self.state, chunk);
        try lua.protectedCall(self.state, 0, lua.MULT_RETURN, 0);

        const parsed = try decode.parseTuple(
            self.state,
            self.allocator,
            previous_top + 1,
            lua.getTop(self.state) - previous_top,
            types,
            .borrowed,
        );
        lua.setTop(self.state, previous_top);
        return parsed;
    }

    /// Formats and allocates a Lua-facing error message for the callback trampoline to raise.
    /// The message is owned by the Zua allocator and freed after being pushed to Lua.
    pub fn err(self: *Zua, comptime types: anytype, comptime fmt: []const u8, args: anytype) Result(types) {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            return Result(types).errStatic("out of memory");
        };

        return Result(types).errOwned(message);
    }

    /// Recovers the owning Zua instance from a raw `lua_State` pointer.
    /// Called by the callback trampoline to retrieve the Zua context.
    pub fn fromState(state: *lua.State) *Zua {
        _ = lua.getField(state, lua.REGISTRY_INDEX, zua_registry_key);
        defer lua.pop(state, 1);

        const ptr = lua.toLightUserdata(state, -1) orelse unreachable;
        return @ptrCast(@alignCast(ptr));
    }
};

/// Internal trampoline generator used by `Table.setFn`.
pub fn wrap(comptime f: anytype) lua.CFunction {
    const function_info = @typeInfo(@TypeOf(f)).@"fn";
    const ReturnType = function_info.return_type orelse @compileError("callback must have a return type");

    if (!@hasDecl(ReturnType, "value_types")) {
        @compileError("callback must return zua.Result(.{ ... })");
    }

    return struct {
        fn trampoline(state_: ?*lua.State) callconv(.c) c_int {
            const state = state_ orelse unreachable;
            const zua = Zua.fromState(state);
            const baseline = lua.getTop(state);

            const args = Args.init(state, zua.allocator, baseline);
            const result = f(zua, args);

            if (result.failure) |failure| {
                switch (failure) {
                    .static_message => |message| lua.pushString(state, message),
                    .owned_message => |message| {
                        lua.pushString(state, message);
                        zua.allocator.free(message);
                    },
                    .zig_error => |err| lua.pushString(state, @errorName(err)),
                }
                return lua.raiseError(state);
            }

            var success = result;
            defer success.deinit(zua.allocator);

            inline for (ReturnType.value_types, 0..) |_, index| {
                Table.pushValueToStack(state, zua.allocator, success.values[index]);
            }

            return @intCast(ReturnType.value_types.len);
        }
    }.trampoline;
}

var fail_callback_defer_ran = false;
var registry_helper_value: i32 = 1;

fn pushAnswer(zua: *Zua, args: Args) Result(.{i32}) {
    const parsed = args.parse(.{i32}) catch return zua.err(.{i32}, "pushAnswer expects (i32)", .{});

    return Result(.{i32}).owned(zua.allocator, .{parsed[0] + 1});
}

fn failWithDefer(zua: *Zua, args: Args) Result(.{}) {
    _ = args;
    defer fail_callback_defer_ran = true;
    return zua.err(.{}, "callback failed", .{});
}

fn readRegistryValue(zua: *Zua, args: Args) Result(.{i32}) {
    _ = args;

    const registry = zua.registry();
    defer registry.pop();

    const value = registry.getLightUserdata("helper_value", i32) catch return zua.err(.{i32}, "helper value missing", .{});
    value.* += 1;
    return Result(.{i32}).owned(zua.allocator, .{value.* - 1});
}

fn incrementMethod(zua: *Zua, args: Args) Result(.{i32}) {
    const parsed = args.parse(.{ Table, i32 }) catch return zua.err(.{i32}, "counter:increment expects (self, i32)", .{});

    const self_table = parsed[0];
    const next_value = (self_table.get("count", i32) catch return zua.err(.{i32}, "counter.count missing", .{})) + parsed[1];
    self_table.set("count", next_value);
    return Result(.{i32}).owned(zua.allocator, .{next_value});
}

test "zua exec and globals interop" {
    const zua = try Zua.init(std.testing.allocator);
    defer zua.deinit();

    const globals = zua.globals();
    defer globals.pop();

    globals.set("answer", 41);
    try zua.exec("answer = answer + 1");

    try std.testing.expectEqual(@as(i32, 42), try globals.get("answer", i32));
}

test "wrapped callbacks return pushed results" {
    const zua = try Zua.init(std.testing.allocator);
    defer zua.deinit();

    const globals = zua.globals();
    defer globals.pop();
    globals.setFn("inc", pushAnswer);

    try zua.exec("answer = inc(41)");
    try std.testing.expectEqual(@as(i32, 42), try globals.get("answer", i32));
}

test "wrapped callbacks surface Lua errors after Zig defers run" {
    const zua = try Zua.init(std.testing.allocator);
    defer zua.deinit();

    const globals = zua.globals();
    defer globals.pop();
    globals.setFn("fail", failWithDefer);

    fail_callback_defer_ran = false;
    try std.testing.expectError(lua.Error.Runtime, zua.exec("fail()"));
    try std.testing.expect(fail_callback_defer_ran);
}

test "wrapped callbacks count results after deferred cleanup" {
    const zua = try Zua.init(std.testing.allocator);
    defer zua.deinit();

    registry_helper_value = 1;

    const registry = zua.registry();
    defer registry.pop();
    registry.setLightUserdata("helper_value", &registry_helper_value);

    const globals = zua.globals();
    defer globals.pop();
    globals.setFn("next_value", readRegistryValue);

    try zua.exec(
        \\first = next_value()
        \\second = next_value()
        \\third = next_value()
    );

    try std.testing.expectEqual(@as(i32, 1), try globals.get("first", i32));
    try std.testing.expectEqual(@as(i32, 2), try globals.get("second", i32));
    try std.testing.expectEqual(@as(i32, 3), try globals.get("third", i32));
}

test "wrapped method callbacks receive self without popping it" {
    const zua = try Zua.init(std.testing.allocator);
    defer zua.deinit();

    const globals = zua.globals();
    defer globals.pop();

    const counter = zua.createTable(0, 2);
    counter.set("count", 0);
    counter.setFn("increment", incrementMethod);
    globals.set("counter", counter);
    counter.pop();

    try zua.exec(
        \\result = counter:increment(5)
    );

    try std.testing.expectEqual(@as(i32, 5), try globals.get("result", i32));
    const global_counter = try globals.get("counter", Table);
    defer global_counter.pop();
    try std.testing.expectEqual(@as(i32, 5), try global_counter.get("count", i32));
}

test "typed eval decodes returned values directly" {
    const zua = try Zua.init(std.testing.allocator);
    defer zua.deinit();

    const parsed = try zua.eval(.{ i32, bool, []const u8 }, "return 41, true, 'ok'");
    try std.testing.expectEqual(@as(i32, 41), parsed[0]);
    try std.testing.expectEqual(true, parsed[1]);
    try std.testing.expectEqualStrings("ok", parsed[2]);
}
