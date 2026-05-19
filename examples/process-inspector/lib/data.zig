const std = @import("std");
const zua = @import("zua");

// Mocked RAM/process/region system used to make the REPL interactive.
// Not relevant to learning zua.

pub const PID_COUNT = 4;
pub const REGION_COUNT = 3;
pub const CELL_COUNT = 128;

pub const ProcessMeta = struct {
    name: []const u8,
    cmdline: []const u8,
    regions: []const RegionMeta,
};

pub const RegionMeta = struct {
    perms_str: []const u8,
    pathname: []const u8,
};

pub const PROCESSES: [PID_COUNT]ProcessMeta = .{
    .{ .name = "init", .cmdline = "/sbin/init", .regions = &.{
        .{ .perms_str = "r-xp", .pathname = "/sbin/init" },
        .{ .perms_str = "rw-p", .pathname = "[heap]" },
    }},
    .{ .name = "gameengine", .cmdline = "/usr/bin/gameengine --render=vulkan", .regions = &.{
        .{ .perms_str = "r-xp", .pathname = "/usr/bin/gameengine" },
        .{ .perms_str = "rw-p", .pathname = "[heap]" },
        .{ .perms_str = "rwxp", .pathname = "[jit]" },
    }},
    .{ .name = "audiod", .cmdline = "/usr/bin/audiod --daemon", .regions = &.{
        .{ .perms_str = "r-xp", .pathname = "/usr/bin/audiod" },
        .{ .perms_str = "rw-p", .pathname = "[heap]" },
    }},
    .{ .name = "netd", .cmdline = "/usr/bin/netd --port=443", .regions = &.{
        .{ .perms_str = "r-xp", .pathname = "/usr/bin/netd" },
        .{ .perms_str = "rw-p", .pathname = "[heap]" },
    }},
};

// Shape.Object with only __gc. No methods or Value fields. The purpose is
// lifecycle attachment: the Store is stored in the Lua registry, and when
// the registry slot is GC'd, Lua runs __gc which frees the RAM. This ties
// the Zig allocation to Lua's GC without exposing any interface to scripts.

pub const Store = @This();

pub const ZUA_SHAPE = zua.Shape.Object(Store, .{ .__gc = cleanup }, .{
    .name = "Store",
});

ram: *[PID_COUNT][REGION_COUNT][CELL_COUNT]i32,

pub fn init(allocator: std.mem.Allocator) !Store {
    const ram = try allocator.create([PID_COUNT][REGION_COUNT][CELL_COUNT]i32);
    for (0..PID_COUNT) |p| {
        for (0..REGION_COUNT) |r| {
            for (0..CELL_COUNT) |i| {
                ram[p][r][i] = @as(i32, @intCast(p * 1024 + r * 128 + i));
            }
        }
    }
    return .{ .ram = ram };
}

fn cleanup(ctx: *zua.Context, self: *Store) void {
    ctx.heap().destroy(self.ram);
}

// Registry access helpers. registry() pushes a reference to the Lua stack.
// It must be released when done. These helpers do the release internally
// so callers never touch the stack directly.
pub fn get(ctx: *zua.Context) !*Store {
    const reg = ctx.state.registry();
    defer reg.release();
    return reg.get(ctx, "__inspector_store", *Store);
}

pub fn register(ctx: *zua.Context, store: Store) !void {
    const reg = ctx.state.registry();
    defer reg.release();
    try reg.set(ctx, "__inspector_store", store);
}

pub fn read(self: *const Store, ctx: *zua.Context, address: usize) !i32 {
    const pid = address >> 24;
    if (pid >= PID_COUNT) return ctx.failWithFmtTyped(i32, "invalid pid {d}", .{pid});
    const region = (address >> 16) & 0xFF;
    if (region >= REGION_COUNT) return ctx.failWithFmtTyped(i32, "invalid region {d}", .{region});
    const cell = (address & 0xFFFF) / 4;
    if (cell >= CELL_COUNT) return ctx.failWithFmtTyped(i32, "address 0x{x} beyond region", .{address});
    return self.ram[pid][region][cell];
}

pub fn write(self: *Store, ctx: *zua.Context, address: usize, value: i32) !void {
    const pid = address >> 24;
    if (pid >= PID_COUNT) return ctx.failWithFmt("invalid pid {d}", .{pid});
    const region = (address >> 16) & 0xFF;
    if (region >= REGION_COUNT) return ctx.failWithFmt("invalid region {d}", .{region});
    const cell = (address & 0xFFFF) / 4;
    if (cell >= CELL_COUNT) return ctx.failWithFmt("address 0x{x} beyond region", .{address});
    self.ram[pid][region][cell] = value;
}
