const std = @import("std");
const zua = @import("zua");
const DocsHelpers = zua.Docs.Internals.Helpers;

// Typed.Fn creates a typed handle for a Lua callback. The generic
// parameters define the argument and return types. zua uses them to
// decode the args going into the callback and encode the return value
// coming back. Here it takes (Primitive) -> bool.
const CustomFn = zua.Handlers.Typed.Fn(.{zua.Mapper.Primitive}, bool);

// TypedAlias tells zua to decode Lua tables into a Zig union. The
// decode hook handles the shorthand forms: a number becomes { eq = x },
// a function becomes { custom = f }. The hook returns the union variant
// directly. withDocs feeds the Docs generator extra type information
// that struct fields alone cannot capture (shorthand aliases).
//
// takeOwnership on the function handle is critical. Without it the
// handle would be stack-owned and invalid after the decode returns.
// takeOwnership pins it in the Lua registry so it survives across
// callbacks and is cleaned up by __gc when the Selector is done.

pub const Selector = union(enum) {
    pub const ZUA_SHAPE = zua.Shape.TypedAlias(Selector, .{}, .{
        .name = "Selector",
        .description = "Comparison predicate for memory scan results.",
    }).withDecode(decode).withDocs(selectorDocs);

    eq: zua.Mapper.Primitive,
    gt: zua.Mapper.Primitive,
    lt: zua.Mapper.Primitive,
    range: [2]zua.Mapper.Primitive,
    custom: CustomFn,

    pub fn matches(self: *const Selector, comptime T: type, ctx: *zua.Context, value: T) !bool {
        return switch (self.*) {
            .eq => |v| value == try zua.Mapper.Decoder.decode(ctx, v, T),
            .gt => |v| value > try zua.Mapper.Decoder.decode(ctx, v, T),
            .lt => |v| value < try zua.Mapper.Decoder.decode(ctx, v, T),
            .range => |r| value >= try zua.Mapper.Decoder.decode(ctx, r[0], T) and value <= try zua.Mapper.Decoder.decode(ctx, r[1], T),
            .custom => |f| blk: {
                const prim = toPrimitive(value, T);
                break :blk try f.call(ctx, .{prim});
            },
        };
    }
};

fn toPrimitive(value: anytype, comptime T: type) zua.Mapper.Primitive {
    return if (comptime T == i32) zua.Mapper.Primitive{ .integer = value } else if (comptime T == f32) zua.Mapper.Primitive{ .float = @as(f64, value) } else @compileError("unsupported type " ++ @typeName(T));
}

fn decode(ctx: *zua.Context, primitive: zua.Mapper.Primitive) !?Selector {
    return switch (primitive) {
        .table => |tbl| {
            if (tbl.has("custom")) {
                return Selector{ .custom = (try tbl.get(ctx, "custom", CustomFn)).takeOwnership() };
            }
            return null;
        },
        .integer, .float => Selector{ .eq = primitive },
        .function => |f| Selector{ .custom = CustomFn.from(f).takeOwnership() },
        else => ctx.failTyped(?Selector, "expected table, number, or function"),
    };
}

fn selectorDocs(self: *zua.Docs.Generator) !void {
    var alias = zua.Docs.Entry.Alias{
        .name = try self.arena.allocator().dupe(u8, "Selector"),
        .description = try self.arena.allocator().dupe(u8, "Comparison predicate for memory scan results."),
        .values = .empty,
    };

    try addShorthand(&alias, self, CustomFn, "Shorthand for { custom = f }.");
    try addShorthand(&alias, self, f64, "Shorthand for { eq = x }.");

    try addField(&alias, self, "eq", zua.Mapper.Primitive, "Equal to value.");
    try addField(&alias, self, "gt", zua.Mapper.Primitive, "Greater than value.");
    try addField(&alias, self, "lt", zua.Mapper.Primitive, "Less than value.");
    try addField(&alias, self, "range", [2]zua.Mapper.Primitive, "Inclusive lo..hi.");
    try addField(&alias, self, "custom", CustomFn, "Custom Lua function(value) -> bool.");

    try self.aliases.append(self.arena.allocator(), alias);
}

fn addShorthand(alias: *zua.Docs.Entry.Alias, gen: *zua.Docs.Generator, comptime T: type, desc: []const u8) !void {
    const type_str = try DocsHelpers.displayTypeName(gen, T, .field);
    try alias.values.append(gen.arena.allocator(), .{ .type = type_str, .description = try gen.arena.allocator().dupe(u8, desc) });
}

fn addField(alias: *zua.Docs.Entry.Alias, gen: *zua.Docs.Generator, comptime name: []const u8, comptime FieldType: type, desc: []const u8) !void {
    const type_str = try DocsHelpers.displayTypeName(gen, FieldType, .field);
    try alias.values.append(gen.arena.allocator(), .{
        .type = try std.fmt.allocPrint(gen.arena.allocator(), "{{ {s}: {s} }}", .{ name, type_str }),
        .description = try gen.arena.allocator().dupe(u8, desc),
    });
}
