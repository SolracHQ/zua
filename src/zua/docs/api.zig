//! Generates Lua annotation stubs for Zig types exposed through zua.
//!
//! Produces `---@meta` stubs that Lua language servers consume so users
//! get autocompletion and type checking on their Lua code that calls
//! into zua-wrapped APIs. Use `generateGlobals` for a full module of
//! globals or `generateModule` for a single value as a require-able
//! module.
//!
//! Inside docs hooks you receive a `*Generator` and push entries using
//! `Generator.add`, `addBinding`, and the `Entry` namespace types.

const std = @import("std");
const Meta = @import("../shape/metadata.zig");
const Marker = @import("../marker.zig");
const Collect = @import("collect.zig");
const Emit = @import("emit.zig");
const Helpers = @import("helpers.zig");

pub const Entry = @import("types.zig");
pub const Generator = @import("generator.zig").Generator;
pub const Internals = @import("internals.zig");

/// Generates Lua annotation stubs for all entries in the globals struct.
///
/// Walks the fields of `globals` and calls `addBinding` for each one.
/// `Generator.addBinding` handles types, native function wrappers,
/// closures, and plain functions. Nested struct literals are recursed
/// into as sub-modules.
pub fn generateGlobals(allocator: std.mem.Allocator, comptime globals: anytype) ![]const u8 {
    var gen = Generator.init(allocator);
    defer gen.deinit();

    inline for (@typeInfo(@TypeOf(globals)).@"struct".fields) |field| {
        const value = @field(globals, field.name);
        if (comptime @TypeOf(value) == type and !Marker.isNativeFunction(value)) {
            try gen.add(value);
        } else {
            try gen.addBinding(field.name, value);
        }
    }

    return gen.generate();
}

/// Generates Lua annotation stubs for a single value as a require-able module.
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
    const T = if (@TypeOf(value) == type) value else @TypeOf(value);
    var gen = Generator.init(allocator);
    defer gen.deinit();

    try Collect.addType(&gen, Helpers.normalizeRootType(T), true);
    const type_name = Meta.nameOf(Helpers.normalizeRootType(T));

    var out = std.ArrayList(u8).empty;
    try Emit.appendFmt(gen.arena.allocator(), &out, "---@meta {s}\n\n", .{module_name});
    try gen.emitAll(&out, true, false);
    try out.appendSlice(gen.arena.allocator(), "\nreturn ");
    try out.appendSlice(gen.arena.allocator(), type_name);

    return try allocator.dupe(u8, out.items);
}

test {
    std.testing.refAllDecls(@This());
}
