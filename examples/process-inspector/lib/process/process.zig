const std = @import("std");
const zua = @import("zua");

const Permissions = @import("../region/perms.zig").Permissions;
const DataType = @import("../mem/types.zig").DataType;
const Selector = @import("../mem/selector.zig").Selector;
const Region = @import("../region/region.zig").Region;
const RegionList = @import("../region/list.zig").List;
const Entry = @import("../mem/entry.zig").Entry;
const EntryList = @import("../mem/list.zig").List;
const Scanner = @import("../mem/scanner.zig").Scanner;
const Store = @import("../data.zig").Store;
const PROCESSES = @import("../data.zig").PROCESSES;

pub const Process = @This();

// Methods are declared separately from ZUA_SHAPE for readability. Any
// comptime-known struct works. const means zua resolves the whole
// decode/encode pipeline at comptime. Only ZUA_SHAPE itself must be
// pub for zua to see it; methods can stay private.
const methods = .{
    .__tostring = display,
    .regions = zua.Shape.Fn(getRegions, .{
        .description = "Returns regions, optionally filtered by permissions.",
        .args = &.{.{ .name = "filter", .description = "Optional permission filter." }},
    }),
    .scan = zua.Shape.Fn(scan, .{
        .description = "Scans process memory for matching values.",
        .args = &.{
            .{ .name = "dataType", .description = "i32 or f32." },
            .{ .name = "selector", .description = "Comparison predicate." },
            .{ .name = "filter", .description = "Optional permission filter." },
        },
    }),
};

pub const ZUA_SHAPE = zua.Shape.Object(Process, methods, .{
    .name = "Process",
    .description = "A process with metadata and memory scanning.",
});

// Modifier.Value on Object fields exposes them as read-only Lua properties.
// Lua reads p.pid, p.name, p.cmdLine as values but cannot write them.
// The writable counterpart is Modifier.Field (not used here).
pid: zua.Shape.Modifier.Value(usize, .{ .description = "Process ID." }),
name: zua.Shape.Modifier.Value([]const u8, .{ .description = "Process name." }),
cmdLine: zua.Shape.Modifier.Value([]const u8, .{ .description = "Command line." }),

fn display(ctx: *zua.Context, self: *Process) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena(), "Process({d}, {s})", .{ self.pid.value, self.name.value });
}

fn getRegions(ctx: *zua.Context, self: *Process, filter: ?Permissions) !RegionList {
    const perm_filter = filter orelse try Permissions.parseString(ctx, "rw-p");
    const pmeta = &PROCESSES[self.pid.value];
    var regions = std.ArrayList(Region).empty;
    errdefer regions.deinit(ctx.arena());
    for (pmeta.regions, 0..) |reg, r| {
        const perms = try Permissions.parseString(ctx, reg.perms_str);
        if (!perms.hasAll(perm_filter)) continue;
        try regions.append(ctx.arena(), Region{
            .pid = .new(self.pid.value),
            .start = .new((self.pid.value << 24) | (r << 16)),
            .end = .new((self.pid.value << 24) | (r << 16) | 0x200),
            .perms = .new(perms),
            .pathname = .new(try ctx.arena().dupe(u8, reg.pathname)),
            .proc_idx = self.pid.value,
            .region_idx = r,
        });
    }
    return try RegionList.init(ctx, regions.items);
}

fn scan(ctx: *zua.Context, self: *Process, dataType: DataType, selector: Selector, filter: ?Permissions) !EntryList {
    const region_filter = filter orelse try Permissions.parseString(ctx, "rw-p");
    const pmeta = &PROCESSES[self.pid.value];
    var entries = std.ArrayList(Entry).empty;
    errdefer entries.deinit(ctx.arena());
    for (pmeta.regions, 0..) |reg, r| {
        const perms = try Permissions.parseString(ctx, reg.perms_str);
        if (!perms.hasAll(region_filter)) continue;
        const region = Region{
            .pid = .new(self.pid.value),
            .start = .new((self.pid.value << 24) | (r << 16)),
            .end = .new((self.pid.value << 24) | (r << 16) | 0x200),
            .perms = .new(perms),
            .pathname = .new(try ctx.arena().dupe(u8, reg.pathname)),
            .proc_idx = self.pid.value,
            .region_idx = r,
        };
        const region_entries = try Scanner.scanRegion(ctx, &region, dataType, selector);
        try entries.appendSlice(ctx.arena(), region_entries);
    }
    return try EntryList.init(ctx, entries.items);
}
