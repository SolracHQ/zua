const std = @import("std");
const testing = std.testing;
const helpers = @import("../../helpers.zig");
const zua = @import("../../../root.zig");

test "Userdata create allocates writable memory" {
    var test_env = try helpers.setup();
    defer test_env.deinit();

    var handle = zua.Handlers.Any.Userdata.create(test_env.state, @sizeOf(u64));
    const ptr: *u64 = @ptrCast(@alignCast(handle.get().?));
    ptr.* = 0xDEAD;

    try testing.expectEqual(@as(u64, 0xDEAD), ptr.*);
    handle.release();
}

test "Userdata takeOwnership promotes to registry" {
    var test_env = try helpers.setup();
    defer test_env.deinit();

    var handle = zua.Handlers.Any.Userdata.create(test_env.state, @sizeOf(u64));
    const ptr: *u64 = @ptrCast(@alignCast(handle.get().?));
    ptr.* = 42;

    const owned = handle.takeOwnership();
    defer owned.release();

    const after: *u64 = @ptrCast(@alignCast(owned.get().?));
    try testing.expectEqual(@as(u64, 42), after.*);
}

test "Userdata owned creates independent registry reference" {
    var test_env = try helpers.setup();
    defer test_env.deinit();

    var handle = zua.Handlers.Any.Userdata.create(test_env.state, @sizeOf(u64));
    const first = handle.takeOwnership();
    defer first.release();

    const second = first.owned();
    defer second.release();

    const ptr_a: *u64 = @ptrCast(@alignCast(first.get().?));
    const ptr_b: *u64 = @ptrCast(@alignCast(second.get().?));
    try testing.expectEqual(ptr_a, ptr_b);
    try testing.expectEqual(@as(u64, ptr_a.*), ptr_b.*);
}
