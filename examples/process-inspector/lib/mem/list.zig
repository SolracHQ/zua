const std = @import("std");
const zua = @import("zua");

const Entry = @import("entry.zig").Entry;
const Selector = @import("selector.zig").Selector;
const Store = @import("../data.zig").Store;

pub const List = @This();

// Methods are declared separately from ZUA_SHAPE for readability. Any
// comptime-known struct works. const means zua resolves the whole
// decode/encode pipeline at comptime. Only ZUA_SHAPE itself must be
// pub for zua to see it; methods can stay private.
const methods = .{
    .__gc = cleanup,
    .__tostring = display,
    .filter = zua.Shape.Fn(filter, .{
        .description = "Keeps only entries matching the given predicate.",
        .args = &.{
            .{ .name = "selector", .description = "Comparison predicate." },
        },
    }),
    .clone = zua.Shape.Fn(clone, .{
        .description = "Returns a new list with the same entries.",
    }),
};

// Shape.List auto-generates __index, __len, get, and iter from the
// getElements accessor. filter uses the same in-place ownership
// pattern as ProcList: read each entry, release non-matches, shrink.
pub const ZUA_SHAPE = zua.Shape.List(List, getElements, methods, .{
    .name = "EntryList",
    .description = "A collection of Entry objects.",
});

entries: std.ArrayList(zua.Handlers.Typed.Object(Entry)),

fn getElements(self: *List) []zua.Handlers.Typed.Object(Entry) {
    return self.entries.items;
}

// Object.create pushes onto the Lua stack. takeOwnership pops that
// reference and moves it to the Lua registry (creating an owned handle).
// Without takeOwnership every create would leave a value on the stack,
// eventually overflowing it.
pub fn init(ctx: *zua.Context, elements: []Entry) !List {
    var list = List{ .entries = std.ArrayList(zua.Handlers.Typed.Object(Entry)).empty };
    errdefer {
        for (list.entries.items) |e| e.release();
        list.entries.deinit(ctx.heap());
    }
    for (elements) |entry| {
        try list.entries.append(ctx.heap(), zua.Handlers.Typed.Object(Entry).create(ctx.state, entry).takeOwnership());
    }
    return list;
}

fn cleanup(ctx: *zua.Context, self: *List) void {
    for (self.entries.items) |e| e.release();
    self.entries.deinit(ctx.heap());
}

fn display(ctx: *zua.Context, self: *List) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena(), "EntryList({d} entries)", .{self.entries.items.len});
}

// In-place filter, re-reads each entry's value from the Store and keeps
// only entries matching the selector. Non-matching entries are released
// and the backing ArrayList is shrunk.
fn filter(ctx: *zua.Context, self: *List, selector: Selector) !void {
    const store = try Store.get(ctx);
    var write: usize = 0;
    for (self.entries.items) |entry| {
        const e = entry.get();
        const raw = try store.read(ctx, e.address.value);
        const matched = switch (e.data_type) {
            .i32 => try selector.matches(i32, ctx, raw),
            .f32 => try selector.matches(f32, ctx, @as(f32, @bitCast(raw))),
        };
        if (matched) {
            self.entries.items[write] = entry;
            write += 1;
        } else {
            entry.release();
        }
    }
    self.entries.shrinkAndFree(ctx.heap(), write);
}

// owned() copies the handle without deleting the original. clone uses
// owned() because the source list keeps its handles. takeOwnership
// would move and leave the source empty.
fn clone(ctx: *zua.Context, self: *List) !List {
    var out = std.ArrayList(zua.Handlers.Typed.Object(Entry)).empty;
    errdefer out.deinit(ctx.heap());
    for (self.entries.items) |entry| {
        const owned = entry.owned();
        errdefer owned.release();
        try out.append(ctx.heap(), owned);
    }
    return List{ .entries = out };
}
