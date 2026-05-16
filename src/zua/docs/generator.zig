//! Runtime scaffolding for the docs generator. Use this when you need
//! extra flexibility, like inside a docs hook. Most common usecases
//! (documenting a struct of globals for an embed instance or a dylib
//! module) are handled by `Docs.generateGlobals` and `Docs.generateModule`
//! directly.

const std = @import("std");
const Context = @import("../context.zig");
const Handlers = @import("../handlers/api.zig");
const RawFunction = @import("../handlers/any/function.zig").Function;
const RawTable = @import("../handlers/any/table.zig").Table;
const RawUserdata = @import("../handlers/any/userdata.zig").Userdata;
const Mapper = @import("../mapper/api.zig");
const ShapeData = @import("../shape/shape_data.zig");
const Marker = @import("../marker.zig");
const Internals = @import("internals.zig");
const Helpers = Internals.Helpers;
const Types = Internals.Types;
const Collect = Internals.Collect;
const Emit = Internals.Emit;

pub const Generator = @This();

classes: std.ArrayList(Types.Table),
objects: std.ArrayList(Types.Object),
aliases: std.ArrayList(Types.Alias),
functions: std.StringHashMap(Types.Function),
bindings: std.ArrayList(Types.Binding),
class_map: std.StringHashMap(void),
object_map: std.StringHashMap(void),
alias_map: std.StringHashMap(void),
arena: std.heap.ArenaAllocator,
heap: std.mem.Allocator,

/// Creates a new generator. All output strings are arena-allocated and
/// freed together in `deinit`.
pub fn init(allocator: std.mem.Allocator) Generator {
    return Generator{
        .classes = std.ArrayList(Types.Table).empty,
        .objects = std.ArrayList(Types.Object).empty,
        .aliases = std.ArrayList(Types.Alias).empty,
        .functions = std.StringHashMap(Types.Function).init(allocator),
        .bindings = std.ArrayList(Types.Binding).empty,
        .class_map = std.StringHashMap(void).init(allocator),
        .object_map = std.StringHashMap(void).init(allocator),
        .alias_map = std.StringHashMap(void).init(allocator),
        .arena = std.heap.ArenaAllocator.init(allocator),
        .heap = allocator,
    };
}

pub fn deinit(self: *Generator) void {
    self.class_map.deinit();
    self.object_map.deinit();
    self.alias_map.deinit();
    self.functions.deinit();
    self.arena.deinit();
}

/// Documents a type. Only `.table`, `.object`, and `.ptr` strategies are
/// accepted. Functions and closures must use `addBinding` instead.
pub fn add(self: *Generator, comptime T: type) !void {
    if (comptime ShapeData.isFunction(T)) {
        @compileError("use addBinding instead of add for Shape.Fn wrappers");
    }
    const strategy = ShapeData.strategyOf(T);
    switch (strategy) {
        .table, .alias, .typed_alias, .object, .ptr => return Collect.addType(self, Helpers.normalizeRootType(T), true),
        .closure => @compileError("closures require addBinding, not add"),
        .function => @compileError("function types require addBinding, not add"),
        .default => unreachable,
    }
}

/// Documents a named binding. Accepts types, `Shape.Fn` wrappers, closures,
/// and plain Zig functions.
pub fn addBinding(self: *Generator, name: []const u8, value: anytype) !void {
    const T = @TypeOf(value);

    if (comptime T == type and ShapeData.isFunction(value)) {
        try Collect.addWrappedFunction(self, value, false, null, name, name);
        try self.bindings.append(self.arena.allocator(), .{
            .var_name = try Helpers.persist(self, name),
            .ref = .{ .kind = .function, .key = try Helpers.persist(self, name) },
        });
        return;
    }

    if (comptime ShapeData.isFunction(T)) {
        try Collect.addWrappedFunction(self, T, false, null, name, name);
        try self.bindings.append(self.arena.allocator(), .{
            .var_name = try Helpers.persist(self, name),
            .ref = .{ .kind = .function, .key = try Helpers.persist(self, name) },
        });
        return;
    }

    if (comptime @typeInfo(T) == .@"struct" and ShapeData.strategyOf(T) == .closure) {
        try Collect.addWrappedFunction(self, T, false, null, name, name);
        try self.bindings.append(self.arena.allocator(), .{
            .var_name = try Helpers.persist(self, name),
            .ref = .{ .kind = .function, .key = try Helpers.persist(self, name) },
        });
        return;
    }

    try Collect.addType(self, Helpers.normalizeRootType(T), true);
    const kind: Types.RefKind = if (comptime Helpers.shouldEmitAlias(Helpers.normalizeRootType(T))) .alias else .class;
    try self.bindings.append(self.arena.allocator(), .{
        .var_name = try Helpers.persist(self, name),
        .ref = .{ .kind = kind, .key = try Helpers.persist(self, ShapeData.nameOf(Helpers.normalizeRootType(T))) },
    });
}

/// Produces the full `---@meta _` stub output for all collected entries.
/// The returned slice is arena-allocated and valid until the generator is
/// deinitialized.
pub fn generate(self: *Generator) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.arena.allocator(), "---@meta _\n\n");
    try emitAll(self, &out, false, true);
    return out.toOwnedSlice(self.arena.allocator());
}

/// Emits all collected entries (classes, objects, aliases, functions,
/// bindings) into the output buffer.
pub fn emitAll(self: *Generator, out: *std.ArrayList(u8), use_local: bool, emit_bindings: bool) !void {
    var first = true;
    for (self.classes.items) |doc| {
        if (!first) try out.appendSlice(self.arena.allocator(), "\n");
        first = false;
        try Emit.emitTableStub(self.arena.allocator(), out, doc);
    }
    for (self.objects.items) |doc| {
        if (!first) try out.appendSlice(self.arena.allocator(), "\n");
        first = false;
        try Emit.emitObjectStub(self.arena.allocator(), out, doc);
    }
    for (self.aliases.items) |doc| {
        if (!first) try out.appendSlice(self.arena.allocator(), "\n");
        first = false;
        try Emit.emitAliasStub(self.arena.allocator(), out, doc);
    }
    {
        var it = self.functions.iterator();
        while (it.next()) |entry| {
            if (!first) try out.appendSlice(self.arena.allocator(), "\n");
            first = false;
            try Emit.emitFunctionStub(self.arena.allocator(), out, entry.value_ptr.*, use_local);
        }
    }
    if (emit_bindings) {
        for (self.bindings.items) |binding| {
            if (std.mem.eql(u8, binding.var_name, binding.ref.key)) continue;
            if (!first) try out.appendSlice(self.arena.allocator(), "\n");
            first = false;
            try Emit.appendFmt(self.arena.allocator(), out, "{s} = {s}", .{ binding.var_name, binding.ref.key });
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}
