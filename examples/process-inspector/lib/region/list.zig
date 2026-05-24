const std = @import("std");
const zua = @import("zua");

const Region = @import("region.zig").Region;
const Entry = @import("../mem/entry.zig").Entry;
const EntryList = @import("../mem/list.zig").List;
const Scanner = @import("../mem/scanner.zig").Scanner;
const DataType = @import("../mem/types.zig").DataType;
const Selector = @import("../mem/selector.zig").Selector;

pub const List = @This();

// Methods are declared separately from ZUA_SHAPE for readability. Any
// comptime-known struct works. const means zua resolves the whole
// decode/encode pipeline at comptime. Only ZUA_SHAPE itself must be
// pub for zua to see it; methods can stay private.
const methods = .{
    .__gc = cleanup,
    .__tostring = display,
    .clone = zua.Shape.Fn(clone, .{
        .description = "Returns a new list with the same regions.",
    }),
    .scan = zua.Shape.Fn(scan, .{
        .description = "Scans all regions for matching values.",
        .args = &.{
            .{ .name = "dataType", .description = "i32 or f32." },
            .{ .name = "selector", .description = "Comparison predicate." },
        },
    }),
};

// Shape.List auto-generates __index, __len, get, and iter from the
// getElements accessor. The ownership model follows the same pattern
// as init (create + takeOwnership).
pub const ZUA_SHAPE = zua.Shape.List(List, getElements, methods, .{
    .name = "RegionList",
    .description = "A collection of Region objects.",
});

regions: std.ArrayList(zua.Handlers.Typed.Object(Region)),

fn getElements(self: *List) []zua.Handlers.Typed.Object(Region) {
    return self.regions.items;
}

// Object.create pushes onto the Lua stack. takeOwnership pops that
// reference and moves it to the Lua registry (creating an owned handle).
// Without takeOwnership every create would leave a value on the stack,
// eventually overflowing it.
pub fn init(ctx: *zua.Context, elements: []Region) !List {
    var list = List{ .regions = std.ArrayList(zua.Handlers.Typed.Object(Region)).empty };
    errdefer {
        for (list.regions.items) |r| r.release();
        list.regions.deinit(ctx.heap());
    }
    for (elements) |region| {
        try list.regions.append(ctx.heap(), zua.Handlers.Typed.Object(Region).create(ctx.state, region).takeOwnership());
    }
    return list;
}

fn cleanup(ctx: *zua.Context, self: *List) void {
    for (self.regions.items) |r| r.release();
    self.regions.deinit(ctx.heap());
}

fn display(ctx: *zua.Context, self: *List) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena(), "RegionList({d} regions)", .{self.regions.items.len});
}

fn clone(ctx: *zua.Context, self: *List) !List {
    var out = std.ArrayList(zua.Handlers.Typed.Object(Region)).empty;
    errdefer out.deinit(ctx.heap());
    for (self.regions.items) |region| {
        const owned = region.owned();
        errdefer owned.release();
        try out.append(ctx.heap(), owned);
    }
    return List{ .regions = out };
}

fn scan(ctx: *zua.Context, self: *List, dataType: DataType, selector: Selector) !EntryList {
    var entries = std.ArrayList(Entry).empty;
    errdefer entries.deinit(ctx.arena());
    for (self.regions.items) |region| {
        const region_entries = try Scanner.scanRegion(ctx, region.get(), dataType, selector);
        try entries.appendSlice(ctx.arena(), region_entries);
    }
    return try EntryList.init(ctx, entries.items);
}
