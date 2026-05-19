const std = @import("std");
const zua = @import("zua");

const DataType = @import("types.zig").DataType;
const Entry = @import("entry.zig").Entry;
const Selector = @import("selector.zig").Selector;
const Store = @import("../data.zig").Store;
const Region = @import("../region/region.zig").Region;

// Scanner iterates the Store RAM directly using the region's proc_idx
// and region_idx. No address-to-cell lookup needed.

pub const Scanner = @This();

pub fn scanRegion(ctx: *zua.Context, region: *const Region, dataType: DataType, selector: Selector) ![]Entry {
    if (!region.perms.value.has(.read)) {
        try ctx.failWithFmt("region at 0x{x} is not readable", .{region.start.value});
    }
    const store = try Store.get(ctx);
    const cells = &store.ram[region.proc_idx][region.region_idx];

    var entries = std.ArrayList(Entry).empty;
    errdefer entries.deinit(ctx.arena());

    for (0..cells.len) |cell| {
        const raw = cells[cell];
        const matched = switch (dataType) {
            .i32 => try selector.matches(i32, ctx, raw),
            .f32 => try selector.matches(f32, ctx, @as(f32, @bitCast(raw))),
        };
        if (matched) {
            try entries.append(ctx.arena(), Entry{
                .pid = .new(region.pid.value),
                .address = .new(region.start.value + cell * 4),
                .perms = .new(region.perms.value),
                .data_type = dataType,
            });
        }
    }
    return entries.toOwnedSlice(ctx.arena());
}
