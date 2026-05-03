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

pub const Docs = @This();

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
const emit = @import("emit.zig");

pub const Doc = types.Doc;

/// Internal cache that maps `@typeName` keys to collected `Doc` entries.
cache: std.StringHashMap(Doc),
/// Arena that owns all doc strings and intermediate allocations.
arena: std.heap.ArenaAllocator,
/// Persistent allocator used for the cache hash map.
heap: std.mem.Allocator,

/// Creates a new stub generator using `allocator` for its cache and arena.
///
/// Generated strings and intermediate docs are stored in the internal arena
/// and released together in `deinit`.
///
/// Arguments:
/// - allocator: An allocator that must live at least as long as the generator.
///
/// Returns:
/// - Docs: A new generator with an empty cache and initialized arena.
///
/// Example:
/// ```zig
/// var d = Docs.init(allocator);
/// defer d.deinit();
/// ```
pub fn init(allocator: std.mem.Allocator) Docs {
    return Docs{
        .cache = std.StringHashMap(Doc).init(allocator),
        .arena = std.heap.ArenaAllocator.init(allocator),
        .heap = allocator,
    };
}

/// Releases all memory owned by the generator.
///
/// After calling `deinit`, the generator and any slices obtained from it
/// become invalid.
///
/// Example:
/// ```zig
/// var d = Docs.init(allocator);
/// defer d.deinit();
/// ```
pub fn deinit(self: *Docs) void {
    self.cache.deinit();
    self.arena.deinit();
}

/// Adds a type, native wrapper, or plain Zig function to the docs cache.
///
/// Plain Zig functions are documented as `NativeFn(function, .{}, .{})`, mirroring
/// the encoder behavior when they are pushed into Lua.
///
/// Repeated additions of the same type or function are ignored after the first
/// cached entry is created.
///
/// Arguments:
/// - item: A Zig type, a `NativeFn` / `Closure` wrapper, or a plain Zig function.
///
/// Example:
/// ```zig
/// try d.add(MyZuaType);
/// try d.add(myZigFunction);
/// ```
pub fn add(self: *Docs, item: anytype) !void {
    const ItemType = @TypeOf(item);

    if (ItemType == type) {
        const T = helpers.normalizeRootType(item);
        if (comptime helpers.isNativeWrapperType(T)) {
            return collect.addWrappedFunction(self, T{}, false, null, T.name, T.name);
        }
        if (comptime helpers.isTypedFunctionHandle(T)) return;
        return collect.addType(self, T, true);
    }

    if (comptime @typeInfo(ItemType) == .@"fn") {
        const wrapped = Native.new(item, .{}, .{});
        return collect.addWrappedFunction(self, wrapped, false, null, wrapped.name, wrapped.name);
    }

    if (comptime helpers.isNativeWrapperType(ItemType)) {
        return collect.addWrappedFunction(self, item, false, null, item.name, item.name);
    }

    return collect.addType(self, helpers.normalizeRootType(ItemType), true);
}

/// Generates Lua stub text for all collected docs.
///
/// The output is prefixed with `---@meta _` and contains the full set of
/// `---@class`, `---@alias`, `---@param`, `---@return`, and `function`
/// annotations for every cached entry.
///
/// Returns:
/// - []const u8: Arena-backed slice of generated Lua annotation text.
///   Remains valid until the generator is deinitialized.
///
/// Example:
/// ```zig
/// const stubs = try d.generate();
/// ```
pub fn generate(self: *Docs) ![]const u8 {
    return self.generateImpl(null);
}

/// Generates Lua stub text directly from a module-like struct literal.
///
/// The output is prefixed with `---@meta {module_name}`.
/// If `module_name` is null, the prefix is `---@meta _`.
///
/// This is a convenience entry point that creates a temporary generator,
/// populates it from the struct fields, emits the stubs, and returns the
/// result via the caller's allocator.
///
/// Arguments:
/// - allocator: Allocator used for the generated output.
/// - module: A struct literal whose fields are types or functions to document.
/// - module_name: Optional name for the `---@meta` annotation.
///
/// Returns:
/// - []const u8: Allocator-owned slice of generated Lua annotation text.
///   The caller is responsible for freeing it.
///
/// Example:
/// ```zig
/// const stubs = try Docs.generateModule(allocator, .{
///     myOpenFunction,
///     myCloseFunction,
/// }, "mymodule");
/// // Result: stubs contains ---@meta mymodule with function stubs
/// // for myOpenFunction and myCloseFunction.
/// ```
pub fn generateModule(
    allocator: std.mem.Allocator,
    module: anytype,
    module_name: ?[]const u8,
) ![]const u8 {
    var generator = Docs.init(allocator);
    defer generator.deinit();
    try generator.addModuleValues(module);
    const generated = try generator.generateImpl(module_name);
    return allocator.dupe(u8, generated);
}

/// Iterates over the fields of a struct literal and adds each value to the
/// docs cache.
fn addModuleValues(self: *Docs, module: anytype) anyerror!void {
    try collect.addModuleValues(self, module);
}

/// Internal implementation shared by `generate` and `generateModule`.
///
/// Walks the cache entries in insertion order and delegates to the appropriate
/// emitter function for each `Doc` variant.
fn generateImpl(self: *Docs, module: ?[]const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var it = self.cache.iterator();
    var first = true;

    const module_name = if (module) |name|
        try std.fmt.allocPrint(self.arena.allocator(), "---@meta {s}\n\n", .{name})
    else
        "---@meta _\n\n";
    try out.appendSlice(self.arena.allocator(), module_name);

    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .PlaceHolder => continue,
            .Table => |doc| {
                if (!first) try out.appendSlice(self.arena.allocator(), "\n");
                first = false;
                try emit.emitTableStub(self.arena.allocator(), &out, doc);
            },
            .Function => |doc| {
                if (!first) try out.appendSlice(self.arena.allocator(), "\n");
                first = false;
                try emit.emitFunctionStub(self.arena.allocator(), &out, doc, null);
            },
            .Object => |doc| {
                if (!first) try out.appendSlice(self.arena.allocator(), "\n");
                first = false;
                try emit.emitObjectStub(self.arena.allocator(), &out, doc);
            },
            .Alias => |doc| {
                if (!first) try out.appendSlice(self.arena.allocator(), "\n");
                first = false;
                try emit.emitAliasStub(self.arena.allocator(), &out, doc);
            },
        }
    }

    return out.toOwnedSlice(self.arena.allocator());
}

test {
    std.testing.refAllDecls(@This());
}
