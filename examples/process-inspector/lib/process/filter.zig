const std = @import("std");
const zua = @import("zua");

const Process = @import("process.zig").Process;

// Table strategy with a decode hook so Lua callers can pass a plain string
// as shorthand for { name = s }. zua calls decode when decoding a Lua value
// into Filter. Returning null falls through to the normal table decode path.
pub const Filter = @This();

pid: ?usize = null,
name: ?[]const u8 = null,
cmdLine: ?[]const u8 = null,

pub const ZUA_SHAPE = zua.Shape.Table(Filter, .{}, .{
    .name = "Filter",
    .description = "Process filter criteria.",
})
    .withDecode(decode)
    .withDocs(filterDocs);

pub fn matches(self: Filter, proc: *const Process) bool {
    if (self.pid) |pid| if (proc.pid.value != pid) return false;
    if (self.name) |name| if (!std.mem.eql(u8, proc.name.value, name)) return false;
    if (self.cmdLine) |cmd| if (!std.mem.eql(u8, proc.cmdLine.value, cmd)) return false;
    return true;
}

fn decode(_: *zua.Context, prim: zua.Mapper.Primitive) !?Filter {
    return switch (prim) {
        .string => |s| Filter{ .name = s },
        else => null,
    };
}

fn filterDocs(self: *zua.Docs.Generator) !void {
    var alias = zua.Docs.Entry.Alias{
        .name = try self.arena.allocator().dupe(u8, "Filter"),
        .description = try self.arena.allocator().dupe(u8, "Process filter criteria. Accepts a table with optional fields, or a string (shorthand for { name = s })."),
        .values = .empty,
    };
    const shape = try zua.Docs.Internals.Helpers.structToAliasShape(self, Filter);
    try alias.values.append(self.arena.allocator(), .{
        .type = try self.arena.allocator().dupe(u8, "string"),
        .description = "Shorthand for { name = s }.",
    });
    try alias.values.append(self.arena.allocator(), .{
        .type = shape,
        .description = "Table of filter criteria.",
    });
    try self.aliases.append(self.arena.allocator(), alias);
}
