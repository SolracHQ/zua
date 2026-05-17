const std = @import("std");
const testing = std.testing;
const helpers = @import("../../helpers.zig");
const zua = @import("../../../root.zig");

const Data = struct {
    pub const ZUA_SHAPE = zua.Shape.Object(Data, .{}, .{});
    x: i32,
};

test "Typed.Object create and get payload" {
    var test_env = try helpers.setup();
    defer test_env.deinit();

    const TO = zua.Handlers.Typed.Object(Data);
    var obj = TO.create(test_env.state, Data{ .x = 42 });
    defer obj.release();

    try testing.expectEqual(@as(i32, 42), obj.get().x);
}

test "Typed.Object takeOwnership promotes to registry" {
    var test_env = try helpers.setup();
    defer test_env.deinit();

    const TO = zua.Handlers.Typed.Object(Data);
    var obj = TO.create(test_env.state, Data{ .x = 99 });
    const owned = obj.takeOwnership();
    defer owned.release();

    try testing.expectEqual(@as(i32, 99), owned.get().x);
}

test "Typed.Object owned creates second registry ref" {
    var test_env = try helpers.setup();
    defer test_env.deinit();

    const TO = zua.Handlers.Typed.Object(Data);
    var obj = TO.create(test_env.state, Data{ .x = 7 });
    const first = obj.takeOwnership();
    defer first.release();

    const second = first.owned();
    defer second.release();

    try testing.expectEqual(@as(i32, 7), first.get().x);
    try testing.expectEqual(@as(i32, 7), second.get().x);
}
