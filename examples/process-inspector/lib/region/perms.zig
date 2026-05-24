const std = @import("std");
const zua = @import("zua");
const Mapper = zua.Mapper;

// Shape.Table by default decodes Lua tables into Zig structs. withDecode
// adds a hook that fires before the table path. If the hook returns a
// non-null value that is used instead. Here the hook lets callers pass
// a string ("rwxp"), an integer bitfield, or a table of permission names.
// Returning null from the hook falls through to the normal table decode.

pub const Permissions = @This();

pub const Permission = enum(u8) {
    read = 1 << 0,
    write = 1 << 1,
    execute = 1 << 2,
    shared = 1 << 3,
    private = 1 << 4,
};

bits: u8,

pub const ZUA_SHAPE = zua.Shape.Table(Permissions, .{ .__tostring = display }, .{
    .name = "Permissions",
    .description = "Memory region permission flags.",
}).withDecode(decode);

pub fn has(self: Permissions, perm: Permission) bool {
    return (self.bits & @intFromEnum(perm)) != 0;
}

pub fn hasAll(self: Permissions, required: Permissions) bool {
    return (self.bits & required.bits) == required.bits;
}

pub fn parseString(_: *zua.Context, s: []const u8) !Permissions {
    if (s.len != 4) return error.InvalidPermissions;
    var bits: u8 = 0;
    if (s[0] == 'r') bits |= @intFromEnum(Permission.read);
    if (s[1] == 'w') bits |= @intFromEnum(Permission.write);
    if (s[2] == 'x') bits |= @intFromEnum(Permission.execute);
    if (s[3] == 's') bits |= @intFromEnum(Permission.shared);
    if (s[3] == 'p') bits |= @intFromEnum(Permission.private);
    return .{ .bits = bits };
}

fn display(_: *zua.Context, self: Permissions) ![]const u8 {
    var buf: [4]u8 = [_]u8{ '-', '-', '-', '-' };
    if (self.has(.read)) buf[0] = 'r';
    if (self.has(.write)) buf[1] = 'w';
    if (self.has(.execute)) buf[2] = 'x';
    if (self.has(.shared)) buf[3] = 's';
    if (self.has(.private)) buf[3] = 'p';
    return std.fmt.allocPrint(std.heap.page_allocator, "{s}", .{&buf}) catch @panic("oom");
}

fn decode(ctx: *zua.Context, value: Mapper.Primitive) !?Permissions {
    return switch (value) {
        .integer => |n| blk: {
            const bits = std.math.cast(u8, n) orelse
                return ctx.failTyped(?Permissions, "integer out of range");
            break :blk .{ .bits = bits };
        },
        .string => |s| parseString(ctx, s) catch |err| {
            return ctx.failWithFmtTyped(?Permissions, "invalid permission string: {s}", .{@errorName(err)});
        },
        .table => |t| {
            var perms: Permissions = .{ .bits = 0 };
            var idx: usize = 1;
            while (t.has(idx)) {
                const name = try t.get(ctx, idx, []const u8);
                const p = if (std.mem.eql(u8, name, "read")) Permission.read
                else if (std.mem.eql(u8, name, "write")) Permission.write
                else if (std.mem.eql(u8, name, "execute")) Permission.execute
                else if (std.mem.eql(u8, name, "shared")) Permission.shared
                else if (std.mem.eql(u8, name, "private")) Permission.private
                else return ctx.failTyped(?Permissions, "unknown permission");
                perms.bits |= @intFromEnum(p);
                idx += 1;
            }
            if (idx == 1) return ctx.failTyped(?Permissions, "permission table is empty");
            return perms;
        },
        else => ctx.failTyped(?Permissions, "expected string, integer, or table"),
    };
}
