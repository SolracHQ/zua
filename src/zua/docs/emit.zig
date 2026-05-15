//! Lua stub emission functions.
//!
//! Converts collected doc entries into Lua-language-server annotation strings
//! (`---@class`, `---@field`, `---@param`, `---@return`,
//! `---@alias`, `---|`). Each emitter appends to a shared `ArrayList(u8)`.

const std = @import("std");
const Types = @import("types.zig");
const Table = Types.Table;
const Function = Types.Function;
const Object = Types.Object;
const Alias = Types.Alias;
const Operator = Types.Operator;

/// Formats text using the given allocator and appends it to the output buffer.
pub fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    try out.appendSlice(allocator, text);
}

/// Emits a Lua table stub as an `---@class` declaration with `---@field` lines.
/// The class binding always emits `local Name = {}`.
pub fn emitTableStub(allocator: std.mem.Allocator, out: *std.ArrayList(u8), doc: Table) !void {
    try appendFmt(allocator, out, "---@class {s}\n", .{doc.name});
    for (doc.operators.items) |op| {
        if (op.param_type) |pt| {
            try appendFmt(allocator, out, "---@operator {s}({s}): {s}\n", .{ op.name, pt, op.return_type });
        } else {
            try appendFmt(allocator, out, "---@operator {s}: {s}\n", .{ op.name, op.return_type });
        }
    }
    for (doc.fields.items) |field| {
        if (field.description.len > 0) {
            try appendFmt(allocator, out, "---@field {s} {s} # {s}\n", .{ field.name, field.type, field.description });
        } else {
            try appendFmt(allocator, out, "---@field {s} {s}\n", .{ field.name, field.type });
        }
    }
    if (doc.description.len > 0) try appendFmt(allocator, out, "-- {s}\n", .{doc.description});
    try appendFmt(allocator, out, "local {s} = {{}}\n", .{doc.name});
}

/// Emits an opaque object stub as an `---@class` declaration. Objects have no
/// `---@field` annotations since they are opaque from Lua's perspective.
/// The object binding always emits `local Name = {}`.
pub fn emitObjectStub(allocator: std.mem.Allocator, out: *std.ArrayList(u8), doc: Object) !void {
    try appendFmt(allocator, out, "---@class {s}\n", .{doc.name});
    for (doc.operators.items) |op| {
        if (op.param_type) |pt| {
            try appendFmt(allocator, out, "---@operator {s}({s}): {s}\n", .{ op.name, pt, op.return_type });
        } else {
            try appendFmt(allocator, out, "---@operator {s}: {s}\n", .{ op.name, op.return_type });
        }
    }
    if (doc.description.len > 0) try appendFmt(allocator, out, "-- {s}\n", .{doc.description});
    try appendFmt(allocator, out, "local {s} = {{}}\n", .{doc.name});
}

/// Emits a type alias stub as an `---@alias` declaration with `---|` lines for each variant.
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
/// The emission syntax depends on which field is active on the function doc:
/// - `method_of` set: `function Owner:name(...)`.
/// - `field_of` not empty: one `function Owner.field_name(...) end` per entry.
/// - Neither: `function name(...)` when `use_local` is false, `local function name(...)` when true.
///   Methods and field functions always omit `local` regardless of `use_local`.
pub fn emitFunctionStub(allocator: std.mem.Allocator, out: *std.ArrayList(u8), doc: Function, use_local: bool) !void {
    const is_shared = doc.field_of.items.len > 0;

    if (!is_shared) {
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
    }

    if (doc.method_of) |owner| {
        try appendFmt(allocator, out, "function {s}:{s}(", .{ owner, doc.name });
    } else if (doc.field_of.items.len > 0) {
        for (doc.field_of.items, 0..) |fo, i| {
            if (i > 0) try out.appendSlice(allocator, "\n");
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
            try appendFmt(allocator, out, "function {s}.{s}(", .{ fo.owner, fo.field_name });
            for (doc.parameters.items, 0..) |param, pi| {
                if (pi > 0) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, param.name);
            }
            try out.appendSlice(allocator, ") end");
        }
        return;
    } else if (use_local) {
        try appendFmt(allocator, out, "local function {s}(", .{doc.name});
    } else {
        try appendFmt(allocator, out, "function {s}(", .{doc.name});
    }

    for (doc.parameters.items, 0..) |param, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, param.name);
    }
    try out.appendSlice(allocator, ") end\n");
}
