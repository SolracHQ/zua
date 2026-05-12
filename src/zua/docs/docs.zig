//! Lua stub generator for editor and language-server support.
//!
//! `Docs` walks the same metadata and wrapper surface used by the runtime
//! encoder and produces Lua annotation stubs for exposed functions, table
//! strategy types, and object methods. The generated output is intended for
//! tooling such as Lua language servers, not for runtime execution.
//!
//! Usage:
//! ```zig
//! var d = Docs.init(allocator);
//! defer d.deinit();
//! try d.add(MyType);
//! try d.add(myFunction);
//! const stubs = try d.generate();
//! ```

const std = @import("std");
const Context = @import("../state/context.zig");
const Native = @import("../functions/native.zig");
const Handlers = @import("../handlers/handlers.zig");
const RawFunction = @import("../handlers/function.zig").Function;
const RawTable = @import("../handlers/table.zig").Table;
const RawUserdata = @import("../handlers/userdata.zig").Userdata;
const Mapper = @import("../mapper/mapper.zig");
const Meta = @import("../meta/meta.zig");
const helpers = @import("helpers.zig");
const types = @import("types.zig");
const collect = @import("collect.zig");
const Marker = @import("../marker.zig");
const emit = @import("emit.zig");

pub const Table = types.Table;
pub const Function = types.Function;
pub const Object = types.Object;
pub const Alias = types.Alias;
pub const Binding = types.Binding;
pub const Operator = types.Operator;
pub const Ref = types.Ref;
pub const RefKind = types.RefKind;
pub const structToAliasShape = helpers.structToAliasShape;

/// Lua stub generator for editor and language-server support.
///
/// Walks the same metadata and wrapper surface used by the runtime encoder and produces
/// Lua annotation stubs for exposed functions, table-strategy types, and object methods.
///
/// Usage:
/// ```zig
/// var d = Docs.init(allocator);
/// defer d.deinit();
/// try d.add(MyType);
/// try d.add(myFunction);
/// const stubs = try d.generate();
/// ```
pub const Docs = @This();

classes: std.ArrayList(Table),
objects: std.ArrayList(Object),
aliases: std.ArrayList(Alias),
functions: std.StringHashMap(Function),
bindings: std.ArrayList(Binding),
class_map: std.StringHashMap(void),
object_map: std.StringHashMap(void),
alias_map: std.StringHashMap(void),
arena: std.heap.ArenaAllocator,
heap: std.mem.Allocator,

/// Creates a new stub generator. Generated strings are stored in the internal arena
/// and released together in `deinit`.
pub fn init(allocator: std.mem.Allocator) Docs {
    return Docs{
        .classes = std.ArrayList(Table).empty,
        .objects = std.ArrayList(Object).empty,
        .aliases = std.ArrayList(Alias).empty,
        .functions = std.StringHashMap(Function).init(allocator),
        .bindings = std.ArrayList(Binding).empty,
        .class_map = std.StringHashMap(void).init(allocator),
        .object_map = std.StringHashMap(void).init(allocator),
        .alias_map = std.StringHashMap(void).init(allocator),
        .arena = std.heap.ArenaAllocator.init(allocator),
        .heap = allocator,
    };
}

/// Releases all memory owned by the generator. After calling `deinit`, the generator
/// and any slices obtained from it become invalid.
pub fn deinit(self: *Docs) void {
    self.class_map.deinit();
    self.object_map.deinit();
    self.alias_map.deinit();
    self.functions.deinit();
    self.arena.deinit();
}

/// Adds a type, native wrapper, or plain Zig function to the docs generator.
///
/// Plain Zig functions are documented as `NativeFn(function, .{}, .{})`, mirroring
/// the encoder behavior when they are pushed into Lua. Repeated additions of the same
/// type are ignored after the first entry is created.
///
/// Arguments:
/// - item: A Zig type, a `NativeFn` / `Closure` wrapper, or a plain Zig function.
pub fn add(self: *Docs, item: anytype) !void {
    const ItemType = @TypeOf(item);

    if (ItemType == type) {
        const T = helpers.normalizeRootType(item);
        if (comptime Marker.isNativeFunction(T)) {
            return collect.addWrappedFunction(self, T{}, false, null, T.name, T.name);
        }
        if (comptime helpers.isTypedFunctionHandle(T)) return;
        return collect.addType(self, T, true);
    }

    if (comptime @typeInfo(ItemType) == .@"fn") {
        const wrapped = Native.new(item, .{}, .{});
        return collect.addWrappedFunction(self, wrapped, false, null, wrapped.name, wrapped.name);
    }

    if (comptime Marker.isNativeFunction(ItemType)) {
        return collect.addWrappedFunction(self, item, false, null, item.name, item.name);
    }

    return collect.addType(self, helpers.normalizeRootType(ItemType), true);
}

/// Adds a named binding to the output.
///
/// The value determines the binding kind:
/// - NativeFn wrappers are stored as functions and referenced by their display name.
/// - Named types (struct, union, enum, opaque) are stored as table/object/alias stubs
///   and referenced by their `ZUA_META.name`.
///
/// Arguments:
/// - name: The Lua variable name for the binding.
/// - value: A value instance or NativeFn wrapper.
pub fn addBinding(self: *Docs, name: []const u8, value: anytype) !void {
    const T = @TypeOf(value);

    if (comptime Marker.isNativeFunction(T)) {
        try collect.addWrappedFunction(self, value, false, null, name, name);
    } else {
        try collect.addType(self, helpers.normalizeRootType(T), true);
    }

    const ref: Ref = if (comptime Marker.isNativeFunction(T))
        .{ .kind = .function, .key = try helpers.persist(self, name) }
    else
        .{ .kind = if (comptime helpers.shouldEmitAlias(helpers.normalizeRootType(T))) .alias else .class, .key = try helpers.persist(self, Meta.nameOf(helpers.normalizeRootType(T))) };

    try self.bindings.append(self.arena.allocator(), .{
        .var_name = try helpers.persist(self, name),
        .ref = ref,
    });
}

/// Generates Lua stub text for all collected docs prefixed with `---@meta _`.
///
/// Types in the output are available workspace-wide without require.
/// Returns an arena-backed slice valid until the generator is deinitialized.
pub fn generate(self: *Docs) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.arena.allocator(), "---@meta _\n\n");
    try emitAll(self, &out, false, true);
    return out.toOwnedSlice(self.arena.allocator());
}

fn emitAll(self: *Docs, out: *std.ArrayList(u8), use_local: bool, emit_bindings: bool) !void {
    var first = true;
    for (self.classes.items) |doc| {
        if (!first) try out.appendSlice(self.arena.allocator(), "\n");
        first = false;
        try emit.emitTableStub(self.arena.allocator(), out, doc);
    }
    for (self.objects.items) |doc| {
        if (!first) try out.appendSlice(self.arena.allocator(), "\n");
        first = false;
        try emit.emitObjectStub(self.arena.allocator(), out, doc);
    }
    for (self.aliases.items) |doc| {
        if (!first) try out.appendSlice(self.arena.allocator(), "\n");
        first = false;
        try emit.emitAliasStub(self.arena.allocator(), out, doc);
    }
    {
        var it = self.functions.iterator();
        while (it.next()) |entry| {
            if (!first) try out.appendSlice(self.arena.allocator(), "\n");
            first = false;
            try emit.emitFunctionStub(self.arena.allocator(), out, entry.value_ptr.*, use_local);
        }
    }
    if (emit_bindings) {
        for (self.bindings.items) |binding| {
            if (!first) try out.appendSlice(self.arena.allocator(), "\n");
            first = false;
            try emit.appendFmt(self.arena.allocator(), out, "{s} = {s}", .{ binding.var_name, binding.ref.key });
        }
    }
}

/// Generates Lua stub text for a single value as a require-able module.
///
/// The value is treated as a normal table/object/alias type. Struct literal fields
/// become opaque `---@field` annotations. The output has `---@meta <module_name>`
/// and ends with `return TypeName`.
///
/// Arguments:
/// - allocator: Allocator for the returned slice. The returned slice is heap-allocated
///   and owned by the caller.
/// - value: The value instance or NativeFn wrapper to document.
/// - module_name: The module name for the `---@meta` header and `require()` association.
///
/// Returns a caller-owned slice that must be freed with `allocator.free`.
pub fn generateModule(allocator: std.mem.Allocator, comptime value: anytype, module_name: []const u8) ![]const u8 {
    var self = Docs.init(allocator);
    defer self.deinit();

    const T = @TypeOf(value);
    const type_name: []const u8 = comptime if (Marker.isNativeFunction(T))
        module_name
    else
        Meta.nameOf(helpers.normalizeRootType(T));

    if (comptime Marker.isNativeFunction(T)) {
        try collect.addWrappedFunction(&self, value, false, null, module_name, module_name);
    } else {
        try collect.addType(&self, helpers.normalizeRootType(T), true);
    }

    var out = std.ArrayList(u8).empty;
    try emit.appendFmt(self.arena.allocator(), &out, "---@meta {s}\n\n", .{module_name});
    try emitAll(&self, &out, true, false);

    try out.appendSlice(self.arena.allocator(), "\nreturn ");
    try out.appendSlice(self.arena.allocator(), type_name);

    return try allocator.dupe(u8, out.items);
}

test {
    std.testing.refAllDecls(@This());
}
