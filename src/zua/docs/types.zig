//! Doc data types used by the Lua stub generator.
//!
//! Each type carries the metadata required to emit a single annotation stanza
//! (table, function, object, alias, or operator). The emitter walks these
//! structures to produce `---@` LuaLS annotations.

const std = @import("std");

/// Controls how type names are rendered when formatting a display string.
pub const DisplayContext = enum {
    field,
    parameter,
    return_value,
};

/// A Lua metamethod operator annotation for language server support.
pub const Operator = struct {
    name: []const u8,
    param_type: ?[]const u8,
    return_type: []const u8,
    description: []const u8,
};

/// A single field belonging to a table or variant struct.
pub const Field = struct {
    name: []const u8,
    description: []const u8,
    type: []const u8,
};

/// Doc node for a table-shaped type. Emitted as an `---@class` with `---@field` lines.
pub const Table = struct {
    name: []const u8,
    description: []const u8,
    fields: std.ArrayList(Field),
    operators: std.ArrayList(Operator),
};

/// A single parameter in a function signature.
pub const Parameter = struct {
    name: []const u8,
    description: []const u8,
    type: []const u8,
};

/// Doc node for a function stub. Emitted as `---@param` / `---@return` annotated Lua function.
///
/// - When `method_of` is set: emitted as `function Owner:name(...)`.
/// - When `field_of` has entries: emitted as `function Owner.field_name(...) end` per entry.
/// - When neither is set: emitted as `local function name(...)`.
///
/// `method_of` and `field_of` are exclusive. A function should not have both set.
pub const Function = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.ArrayList(Parameter) = .empty,
    returns: std.ArrayList([]const u8) = .empty,
    method_of: ?[]const u8 = null,
    field_of: std.ArrayList(FieldOf) = .empty,
};

/// Records that a function is a `.`-field of a type. Used when a table type
/// has a function-valued attribute. The `field_name` is the attribute name,
/// which may differ from the function's `name`.
pub const FieldOf = struct {
    owner: []const u8,
    field_name: []const u8,
};

/// A single variant entry inside an `---@alias` stanza.
pub const AliasValue = struct {
    type: []const u8,
    description: []const u8,
};

/// Doc node for a tagged union or enum alias. Emitted as `---@alias` with `---|` lines.
pub const Alias = struct {
    name: []const u8,
    description: []const u8,
    values: std.ArrayList(AliasValue),
};

/// Doc node for an object or pointer type. Emitted as an `---@class` with
/// `---@field` annotations for `Shape.Field` / `Shape.Value` marked fields.
pub const Object = struct {
    name: []const u8,
    description: []const u8,
    fields: std.ArrayList(Field),
    operators: std.ArrayList(Operator),
};

/// Discriminated kind for a `Ref`. Determines how the reference key is emitted
/// in binding lines.
pub const RefKind = enum { class, alias, function };

/// References a previously collected doc entry by its display key.
/// Used in `Binding` to point to the target type or function.
pub const Ref = struct {
    kind: RefKind,
    key: []const u8,
};

/// A variable-to-type or variable-to-function binding emitted after all type and
/// function stubs. Emits `var_name = ref_key` (bare global assignment).
pub const Binding = struct {
    var_name: []const u8,
    ref: Ref,
};
