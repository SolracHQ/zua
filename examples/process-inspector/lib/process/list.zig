const std = @import("std");
const zua = @import("zua");

const Process = @import("process.zig").Process;
const Filter = @import("filter.zig").Filter;
const Region = @import("../region/region.zig").Region;
const Permissions = @import("../region/perms.zig").Permissions;
const DataType = @import("../mem/types.zig").DataType;
const Selector = @import("../mem/selector.zig").Selector;
const Entry = @import("../mem/entry.zig").Entry;
const EntryList = @import("../mem/list.zig").List;
const Scanner = @import("../mem/scanner.zig").Scanner;
const PROCESSES = @import("../data.zig").PROCESSES;

pub const List = @This();

// Methods are declared separately from ZUA_SHAPE for readability. Any
// comptime-known struct works. const means zua resolves the whole
// decode/encode pipeline at comptime. Only ZUA_SHAPE itself must be
// pub for zua to see it; methods can stay private.
const methods = .{
    .__gc = cleanup,
    .__tostring = display,
    .filter = zua.Shape.Fn(filter, .{
        .description = "Keeps only processes matching the given criteria, removing the rest.",
        .args = &.{.{ .name = "filter", .description = "Filter with pid, name, or cmdLine." }},
    }),
    .clone = zua.Shape.Fn(clone, .{
        .description = "Returns a new list with the same processes.",
    }),
    .scan = zua.Shape.Fn(scan, .{
        .description = "Scans all processes for matching values.",
        .args = &.{
            .{ .name = "dataType", .description = "i32 or f32." },
            .{ .name = "selector", .description = "Comparison predicate." },
            .{ .name = "filter", .description = "Optional permission filter." },
        },
    }),
};

// Shape.List auto-generates __index, __len, get, and iter from the
// getElements accessor. Lua can index procs[1], get #procs, and
// iterate with `for p in procs do`. The ownership model follows the
// same pattern as init (create + takeOwnership).
pub const ZUA_SHAPE = zua.Shape.List(List, getElements, methods, .{
    .name = "ProcList",
    .description = "A collection of Process objects.",
});

processes: std.ArrayList(zua.Handlers.Typed.Object(Process)),

fn getElements(self: *List) []zua.Handlers.Typed.Object(Process) {
    return self.processes.items;
}

// Object.create pushes onto the Lua stack. takeOwnership pops that
// reference and moves it to the Lua registry (creating an owned handle).
// Without takeOwnership every create would leave a value on the stack,
// eventually overflowing it. The owned handle is released in __gc.
pub fn init(ctx: *zua.Context, elements: []Process) !List {
    var list = List{ .processes = std.ArrayList(zua.Handlers.Typed.Object(Process)).empty };
    errdefer {
        for (list.processes.items) |p| p.release();
        list.processes.deinit(ctx.heap());
    }
    for (elements) |proc| {
        try list.processes.append(ctx.heap(), zua.Handlers.Typed.Object(Process).create(ctx.state, proc).takeOwnership());
    }
    return list;
}

fn cleanup(ctx: *zua.Context, self: *List) void {
    for (self.processes.items) |p| p.release();
    self.processes.deinit(ctx.heap());
}

// In-place filter, matching processes stay, the rest are released.
// This demonstrates the ownership handshake. Each element is an owned
// Object handle. filter releases the ones that don't match, then
// shrinks the backing ArrayList to free the unused slots.
fn filter(ctx: *zua.Context, self: *List, f: Filter) !void {
    var write: usize = 0;
    for (self.processes.items) |proc| {
        if (f.matches(proc.get())) {
            self.processes.items[write] = proc;
            write += 1;
        } else {
            proc.release();
        }
    }
    self.processes.shrinkAndFree(ctx.heap(), write);
}

fn display(ctx: *zua.Context, self: *List) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena(), "ProcList({d} processes)", .{self.processes.items.len});
}

// owned() copies the handle without deleting the original. This is
// different from takeOwnership which moves. clone uses owned() because
// the source list keeps its handles. errdefer ensures the copy is
// released if a later append fails.
fn clone(ctx: *zua.Context, self: *List) !List {
    var out = std.ArrayList(zua.Handlers.Typed.Object(Process)).empty;
    errdefer out.deinit(ctx.heap());
    for (self.processes.items) |proc| {
        const owned = proc.owned();
        errdefer owned.release();
        try out.append(ctx.heap(), owned);
    }
    return List{ .processes = out };
}

fn scan(ctx: *zua.Context, self: *List, dataType: DataType, selector: Selector, perm_filter: ?Permissions) !EntryList {
    const region_filter = perm_filter orelse try Permissions.parseString(ctx, "rw-p");
    var entries = std.ArrayList(Entry).empty;
    errdefer entries.deinit(ctx.arena());
    for (self.processes.items) |proc| {
        const p = proc.get();
        const pid = p.pid.value;
        if (pid >= PROCESSES.len) continue;
        const pmeta = &PROCESSES[pid];
        for (pmeta.regions, 0..) |reg, r| {
            const perms = try Permissions.parseString(ctx, reg.perms_str);
            if (!perms.hasAll(region_filter)) continue;
            const region = Region{
                .pid = .new(pid),
                .start = .new((pid << 24) | (r << 16)),
                .end = .new((pid << 24) | (r << 16) | 0x200),
                .perms = .new(perms),
                .pathname = .new(try ctx.arena().dupe(u8, reg.pathname)),
                .proc_idx = pid,
                .region_idx = r,
            };
            const region_entries = try Scanner.scanRegion(ctx, &region, dataType, selector);
            try entries.appendSlice(ctx.arena(), region_entries);
        }
    }
    return try EntryList.init(ctx, entries.items);
}
