//! Lua stub emission functions.
//!
//! This module converts collected `Doc` values into Lua-language-server
//! annotation strings (`---@class`, `---@field`, `---@param`, `---@return`,
//! `---@alias`, `---|`). Each emitter appends to a shared `ArrayList(u8)`.

const std = @import("std");
const types = @import("types.zig");
const Table = types.Table;
const Function = types.Function;
const Object = types.Object;
const Alias = types.Alias;

/// Formats text using the arena allocator and appends it to the output buffer.
///
/// This is a convenience wrapper around `std.fmt.allocPrint` followed by
/// `appendSlice`. The formatted string is allocated from `allocator` and
/// does not need to be freed separately (it is owned by the output buffer
/// once appended, though the buffer itself holds no ownership).
///
/// Arguments:
/// - allocator: Allocator used for the temporary formatted string.
/// - out: The output buffer to append to.
/// - fmt: A `std.fmt` format string.
/// - args: Format arguments.
pub fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    try out.appendSlice(allocator, text);
}

/// Emits a Lua table stub as an `---@class` declaration.
///
/// Produces `---@field` lines for each field, an optional description comment,
/// a `local name = {}` table literal, and `function` stubs for each method.
///
/// Arguments:
/// - allocator: Arena allocator for temporary formatting allocations.
/// - out: The output buffer to append to.
/// - doc: The table doc to emit.
pub fn emitTableStub(allocator: std.mem.Allocator, out: *std.ArrayList(u8), doc: Table) !void {
    try appendFmt(allocator, out, "---@class {s}\n", .{doc.name});
    for (doc.fields.items) |field| {
        if (field.description.len > 0) {
            try appendFmt(allocator, out, "---@field {s} {s} # {s}\n", .{ field.name, field.type, field.description });
        } else {
            try appendFmt(allocator, out, "---@field {s} {s}\n", .{ field.name, field.type });
        }
    }
    if (doc.description.len > 0) try appendFmt(allocator, out, "-- {s}\n", .{doc.description});
    try appendFmt(allocator, out, "local {s} = {{}}\n", .{doc.name});

    for (doc.methods.items) |method| {
        try out.appendSlice(allocator, "\n");
        try emitFunctionStub(allocator, out, method, doc.name);
    }
}

/// Emits an opaque object stub as an `---@class` declaration.
///
/// Objects have no `---@field` annotations (they are opaque). Only a class
/// declaration, optional description, a placeholder table literal, and
/// method stubs are emitted.
///
/// Arguments:
/// - allocator: Arena allocator for temporary formatting allocations.
/// - out: The output buffer to append to.
/// - doc: The object doc to emit.
pub fn emitObjectStub(allocator: std.mem.Allocator, out: *std.ArrayList(u8), doc: Object) !void {
    try appendFmt(allocator, out, "---@class {s}\n", .{doc.name});
    if (doc.description.len > 0) try appendFmt(allocator, out, "-- {s}\n", .{doc.description});
    try appendFmt(allocator, out, "local {s} = {{}}\n", .{doc.name});

    for (doc.methods.items) |method| {
        try out.appendSlice(allocator, "\n");
        try emitFunctionStub(allocator, out, method, doc.name);
    }
}

/// Emits a type alias stub as an `---@alias` declaration.
///
/// Produces an optional description comment, the `---@alias` line, and `---|`
/// lines for each variant value.
///
/// Arguments:
/// - allocator: Arena allocator for temporary formatting allocations.
/// - out: The output buffer to append to.
/// - doc: The alias doc to emit.
pub fn emitAliasStub(allocator: std.mem.Allocator, out: *std.ArrayList(u8), doc: Alias) !void {
    if (doc.description.len > 0) try appendFmt(allocator, out, "-- {s}\n", .{doc.description});
    try appendFmt(allocator, out, "---@alias {s}\n", .{doc.name});
    for (doc.values.items) |value| {
        if (value.description.len > 0) {
            try appendFmt(allocator, out, "---| {s} # {s}\n", .{ value.type, value.description });
        } else {
            try appendFmt(allocator, out, "---| {s}\n", .{value.type});
        }
    }
}

/// Emits a function stub with `---@param`, `---@return` annotations.
///
/// If `owner_name` is provided, the function is emitted as a method definition
/// (`function Owner:name(...)`); otherwise it is a standalone function.
///
/// Arguments:
/// - allocator: Arena allocator for temporary formatting allocations.
/// - out: The output buffer to append to.
/// - doc: The function doc to emit.
/// - owner_name: If non-null, emit as a method of the given class name.
pub fn emitFunctionStub(allocator: std.mem.Allocator, out: *std.ArrayList(u8), doc: Function, owner_name: ?[]const u8) !void {
    if (doc.description.len > 0) try appendFmt(allocator, out, "-- {s}\n", .{doc.description});
    for (doc.parameters.items) |param| {
        if (param.description.len > 0) {
            try appendFmt(allocator, out, "---@param {s} {s} # {s}\n", .{ param.name, param.type, param.description });
        } else {
            try appendFmt(allocator, out, "---@param {s} {s}\n", .{ param.name, param.type });
        }
    }
    for (doc.returns.items) |ret| {
        try appendFmt(allocator, out, "---@return {s}\n", .{ret});
    }

    if (owner_name) |owner| {
        try appendFmt(allocator, out, "function {s}:{s}(", .{ owner, doc.name });
    } else {
        try appendFmt(allocator, out, "function {s}(", .{doc.name});
    }

    for (doc.parameters.items, 0..) |param, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, param.name);
    }
    try out.appendSlice(allocator, ") end\n");
}
