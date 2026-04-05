//! The main Zig wrapper over Lua 5.4, built to avoid the stack discipline pain.
//!
//! Zua (Zig + Lua) is the heart of the wrapper.
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
const Table = @import("table.zig").Table;
const result_module = @import("result.zig");
const translation = @import("translation.zig");
const ZuaFn = @import("zua_fn.zig");

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
    pub const TraceBackResult = union(enum) {
        Ok: void,
        Runtime: []const u8,
        Syntax: []const u8,
        OutOfMemory: []const u8,
        MessageHandler: []const u8,
        File: []const u8,
        Unknown: []const u8,
    };

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
        return Table.fromStack(self, -1);
    }

    /// Pushes the Lua registry onto the stack and returns an absolute-indexed handle.
    /// Use this to store host state via `setLightUserdata("key", &state)`.
    pub fn registry(self: *Zua) Table {
        lua.pushValue(self.state, lua.REGISTRY_INDEX);
        return Table.fromStack(self, -1);
    }

    /// Creates a new Lua table with optional capacity hints and returns an absolute-indexed handle.
    /// Pass 0 for capacity hints if you don't know the final size; Lua will resize internally.
    pub fn createTable(self: *Zua, array_capacity: i32, record_capacity: i32) Table {
        lua.createTable(self.state, array_capacity, record_capacity);
        return Table.fromStack(self, -1);
    }

    /// Converts a Zig struct, array, tuple, or slice into a Lua table recursively.
    /// Array elements become integer keys; struct fields become string keys.
    /// Nested structs/arrays are converted recursively.
    pub fn tableFrom(self: *Zua, value: anytype) Table {
        const table = self.createTable(translation.inferArrayCapacity(value), translation.inferRecordCapacity(value));
        translation.fillTable(table, value);
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

    /// Executes a Lua chunk and returns the Lua error message with traceback on failure.
    pub fn execTraceback(self: *Zua, source: []const u8) !TraceBackResult {
        const previous_top = lua.getTop(self.state);
        errdefer lua.setTop(self.state, previous_top);

        const chunk = try self.allocator.dupeZ(u8, source);
        defer self.allocator.free(chunk);

        try lua.loadString(self.state, chunk);
        lua.pushTracebackFunction(self.state);
        lua.insert(self.state, -2);
        const errfunc = lua.absIndex(self.state, -2);
        const status = lua.pcall(self.state, 0, 0, errfunc);
        if (status == lua.c.LUA_OK) return .Ok;

        const raw_message = lua.toDisplayString(self.state, -1) orelse "unknown error";
        const message = try self.allocator.dupe(u8, raw_message);

        return switch (status) {
            lua.c.LUA_ERRRUN => .{ .Runtime = message },
            lua.c.LUA_ERRSYNTAX => .{ .Syntax = message },
            lua.c.LUA_ERRMEM => .{ .OutOfMemory = message },
            lua.c.LUA_ERRERR => .{ .MessageHandler = message },
            lua.c.LUA_ERRFILE => .{ .File = message },
            else => .{ .Unknown = message },
        };
    }

    pub fn freeTraceBackResult(self: *Zua, err: TraceBackResult) void {
        switch (err) {
            .Ok => {},
            .Runtime => |msg| self.allocator.free(msg),
            .Syntax => |msg| self.allocator.free(msg),
            .OutOfMemory => |msg| self.allocator.free(msg),
            .MessageHandler => |msg| self.allocator.free(msg),
            .File => |msg| self.allocator.free(msg),
            .Unknown => |msg| self.allocator.free(msg),
        }
    }

    /// Executes a Lua chunk and decodes its return values into a typed tuple.
    /// Example: `const (num, msg) = try zua.eval(.{i32, []const u8}, "return 42, 'ok'")`.
    pub fn eval(self: *Zua, comptime types: anytype, source: []const u8) (lua.Error || translation.ParseError)!translation.ParseResult(types) {
        const previous_top = lua.getTop(self.state);
        errdefer lua.setTop(self.state, previous_top);

        const chunk = try self.allocator.dupeZ(u8, source);
        defer self.allocator.free(chunk);

        try lua.loadString(self.state, chunk);
        try lua.protectedCall(self.state, 0, lua.MULT_RETURN, 0);

        const parsed = try translation.parseTuple(
            self,
            previous_top + 1,
            lua.getTop(self.state) - previous_top,
            types,
            .borrowed,
        );
        lua.setTop(self.state, previous_top);
        return parsed;
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

// Tests

var fail_callback_defer_ran = false;
var registry_helper_value: i32 = 1;

fn pushAnswer(_: *Zua, value: i32) Result(i32) {
    return Result(i32).ok(value + 1);
}

fn failWithDefer(_: *Zua) Result(.{}) {
    defer fail_callback_defer_ran = true;
    return Result(.{}).errStatic("callback failed");
}

fn readRegistryValue(zua: *Zua) Result(i32) {
    const registry = zua.registry();
    defer registry.pop();

    const value = registry.getLightUserdata("helper_value", i32) catch return Result(i32).errStatic("helper value missing");
    value.* += 1;
    return Result(i32).ok(value.* - 1);
}

fn incrementMethod(_: *Zua, self_table: Table, delta: i32) Result(i32) {
    const next_value = (self_table.get("count", i32) catch return Result(i32).errStatic("counter.count missing")) + delta;
    self_table.set("count", next_value);
    return Result(i32).ok(next_value);
}

fn parseSingleInteger(value: i32) translation.ParseError!i32 {
    return value;
}

fn pushAnswerWithTry(_: *Zua, value: i32) !Result(i32) {
    const parsed = try parseSingleInteger(value);
    return Result(i32).ok(parsed + 10);
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
    const inc_config = ZuaFn.ZuaFnErrorConfig{ .parse_error = "inc expects (i32)" };
    globals.setFn("inc", ZuaFn.from(pushAnswer, inc_config));

    try zua.exec("answer = inc(41)");
    try std.testing.expectEqual(@as(i32, 42), try globals.get("answer", i32));
}

test "wrapped callbacks accept error-union results" {
    const zua = try Zua.init(std.testing.allocator);
    defer zua.deinit();

    const globals = zua.globals();
    defer globals.pop();
    const inc_try_config = ZuaFn.ZuaFnErrorConfig{ .parse_error = "inc_try expects (i32)" };
    globals.setFn("inc_try", ZuaFn.from(pushAnswerWithTry, inc_try_config));

    try zua.exec("answer = inc_try(32)");
    try std.testing.expectEqual(@as(i32, 42), try globals.get("answer", i32));
}

test "wrapped callbacks surface Lua errors after Zig defers run" {
    const zua = try Zua.init(std.testing.allocator);
    defer zua.deinit();

    const globals = zua.globals();
    defer globals.pop();
    const fail_config = ZuaFn.ZuaFnErrorConfig{ .parse_error = "fail expects ()" };
    globals.setFn("fail", ZuaFn.from(failWithDefer, fail_config));

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
    const next_value_config = ZuaFn.ZuaFnErrorConfig{ .parse_error = "next_value expects ()" };
    globals.setFn("next_value", ZuaFn.from(readRegistryValue, next_value_config));

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
    const increment_method_config = ZuaFn.ZuaFnErrorConfig{ .parse_error = "counter:increment expects (self, i32)" };
    counter.setFn("increment", ZuaFn.from(incrementMethod, increment_method_config));
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

test "execTraceback returns a traceback string for Lua runtime failures" {
    const zua = try Zua.init(std.testing.allocator);
    defer zua.deinit();

    try std.testing.expectError(lua.Error.Runtime, zua.exec("error('boom')"));
    const err = try zua.execTraceback("error('boom')");
    switch (err) {
        .Runtime => |msg| try std.testing.expect(std.mem.indexOf(u8, msg, "stack traceback:") != null),
        else => try std.testing.expect(false),
    }
    zua.freeTraceBackResult(err);
}
