const std = @import("std");
const testing = std.testing;
const helpers = @import("../../helpers.zig");
const zua = @import("../../../root.zig");
const lua = zua.Bindings.lua;

test "Decoder.pop reads integer from stack and removes it" {
    var test_env = try helpers.setup();
    defer test_env.deinit();

    const ls = test_env.state.luaState;
    lua.pushInteger(ls, 42);
    const top_before = lua.getTop(ls);

    const value = try zua.Mapper.Decoder.pop(&test_env.ctx, i32);
    try testing.expectEqual(@as(i32, 42), value);

    const top_after = lua.getTop(ls);
    try testing.expectEqual(top_before - 1, top_after);
}

test "Decoder.pop reads string from stack and removes it" {
    var test_env = try helpers.setup();
    defer test_env.deinit();

    const ls = test_env.state.luaState;
    lua.pushString(ls, "hello pop");
    const top_before = lua.getTop(ls);

    const value = try zua.Mapper.Decoder.pop(&test_env.ctx, []const u8);
    try testing.expectEqualStrings("hello pop", value);

    const top_after = lua.getTop(ls);
    try testing.expectEqual(top_before - 1, top_after);
}
