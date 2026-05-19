const std = @import("std");
const zua = @import("zua");

const Permissions = @import("perms.zig").Permissions;
const DataType = @import("../mem/types.zig").DataType;
const Selector = @import("../mem/selector.zig").Selector;
const EntryList = @import("../mem/list.zig").List;
const Scanner = @import("../mem/scanner.zig").Scanner;

// Region uses Shape.Object. Modifier.Value on every field means Lua
// reads pid, start, end, perms, pathname as properties but never writes.

pub const Region = @This();

// Methods are declared separately from ZUA_SHAPE for readability. Any
// comptime-known struct works. const means zua resolves the whole
// decode/encode pipeline at comptime. Only ZUA_SHAPE itself must be
// pub for zua to see it; methods can stay private.
const methods = .{
    .__tostring = display,
    .get_size = zua.Shape.Fn(getSize, .{
        .description = "Returns the size of this region.",
    }),
    .scan = zua.Shape.Fn(scan, .{
        .description = "Scans this region for matching values.",
        .args = &.{
            .{ .name = "dataType", .description = "i32 or f32." },
            .{ .name = "selector", .description = "Comparison predicate." },
        },
    }),
};

pub const ZUA_SHAPE = zua.Shape.Object(Region, methods, .{
    .name = "Region",
    .description = "A mapped memory region.",
});

pid: zua.Shape.Modifier.Value(usize, .{ .description = "Process ID." }),
start: zua.Shape.Modifier.Value(usize, .{ .description = "Start address." }),
end: zua.Shape.Modifier.Value(usize, .{ .description = "End address." }),
perms: zua.Shape.Modifier.Value(Permissions, .{ .description = "Permission flags." }),
pathname: zua.Shape.Modifier.Value([]const u8, .{ .description = "Mapped path." }),

// Plain fields used by the scanner to index into the Store's RAM.
// Not exposed to Lua. Set at construction from the RegionRecord.
proc_idx: usize,
region_idx: usize,

fn getSize(self: *const Region) usize {
    return self.end.value - self.start.value;
}

fn scan(ctx: *zua.Context, self: *Region, dataType: DataType, selector: Selector) !EntryList {
    const entries = try Scanner.scanRegion(ctx, self, dataType, selector);
    return try EntryList.init(ctx, entries);
}

fn display(ctx: *zua.Context, self: *Region) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena(), "Region(0x{x}, 0x{x}, {s})", .{ self.start.value, self.end.value, self.pathname.value });
}
