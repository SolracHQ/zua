const std = @import("std");
const lua = @import("lua.zig");
const Table = @import("table.zig").Table;
const decode = @import("decode.zig");

pub const ParseError = decode.ParseError;
pub const ParseResult = decode.ParseResult;

/// Non-owning view over the arguments passed from Lua into a Zig callback.
pub const Args = struct {
    state: *lua.State,
    allocator: std.mem.Allocator,
    baseline: lua.StackIndex,

    /// Creates an argument view for a callback invocation.
    pub fn init(state: *lua.State, allocator: std.mem.Allocator, baseline: lua.StackIndex) Args {
        return .{
            .state = state,
            .allocator = allocator,
            .baseline = baseline,
        };
    }

    /// Returns the number of callback arguments visible to this view.
    pub fn len(self: Args) i32 {
        return self.baseline;
    }

    /// Parses the callback arguments into a typed tuple.
    pub fn parse(self: Args, comptime types: anytype) ParseError!ParseResult(types) {
        return decode.parseTuple(
            self.state,
            self.allocator,
            self.argumentIndex(0),
            self.len(),
            types,
            .borrowed,
        );
    }

    fn argumentIndex(_: Args, index: usize) lua.StackIndex {
        return @as(lua.StackIndex, @intCast(index)) + 1;
    }
};

test "parse typed callback arguments" {
    const zua_mod = @import("zua.zig");

    const zua = try zua_mod.Zua.init(std.testing.allocator);
    defer zua.deinit();

    lua.pushInteger(zua.state, 41);
    lua.pushNumber(zua.state, 2.5);
    lua.pushBoolean(zua.state, true);
    lua.pushString(zua.state, "ok");

    const args = Args.init(zua.state, zua.allocator, 4);
    const parsed = try args.parse(.{ i32, f64, bool, []const u8 });

    try std.testing.expectEqual(@as(i32, 41), parsed[0]);
    try std.testing.expectEqual(@as(f64, 2.5), parsed[1]);
    try std.testing.expectEqual(true, parsed[2]);
    try std.testing.expectEqualStrings("ok", parsed[3]);

    lua.setTop(zua.state, 0);
}

test "reject invalid callback arity" {
    const zua_mod = @import("zua.zig");

    const zua = try zua_mod.Zua.init(std.testing.allocator);
    defer zua.deinit();

    lua.pushInteger(zua.state, 1);

    const args = Args.init(zua.state, zua.allocator, 1);
    try std.testing.expectError(error.InvalidArity, args.parse(.{ i32, i32 }));

    lua.setTop(zua.state, 0);
}

test "parse table receiver argument" {
    const zua_mod = @import("zua.zig");

    const zua = try zua_mod.Zua.init(std.testing.allocator);
    defer zua.deinit();

    const table = zua.createTable(0, 1);
    table.set("count", 5);

    const args = Args.init(zua.state, zua.allocator, 1);
    const parsed = try args.parse(.{Table});

    try std.testing.expectEqual(@as(i32, 5), try parsed[0].get("count", i32));

    parsed[0].pop();
    table.pop();
}
