//! Doc data types used by the Lua stub generator.
//!
//! Each `Doc` variant carries the metadata required to emit a single annotation
//! stanza (table, function, object, alias, or placeholder). The emitter walks
//! these structures to produce `---@` LuaLS annotations.

const std = @import("std");

/// Discriminated union tag for the different kinds of doc nodes the generator
/// can produce.
pub const DocKind = enum {
    Table,
    Function,
    Object,
    Alias,
    PlaceHolder,
};

/// Controls how type names are rendered when formatting a display string.
///
/// The display context affects whether certain type representations are
/// parenthesized or prefixed (e.g. method self parameters are omitted in
/// `parameter` context).
pub const DisplayContext = enum {
    /// Type is rendered for a struct/union field.
    field,
    /// Type is rendered for a function parameter.
    parameter,
    /// Type is rendered for a function return value.
    return_value,
};

/// A single field belonging to a table or variant struct.
///
/// The `type` field contains a human-readable Lua annotation type string such as
/// `"string"`, `"integer"`, or a user-defined class name.
pub const Field = struct {
    /// Display name of the field (e.g. `"x"`, `"name"`).
    name: []const u8,
    /// Human-readable description of the field's purpose.
    description: []const u8,
    /// Lua annotation type string (e.g. `"string"`, `"MyClass"`, `"integer[]"`).
    type: []const u8,
};

/// Doc node for a table-strategy type.
///
/// Emitted as an `---@class` with `---@field` lines for each field and
/// `function` stubs for each method.
pub const Table = struct {
    /// Lua class / variable name of the table.
    name: []const u8,
    /// Human-readable description of the table's purpose.
    description: []const u8,
    /// Ordered list of fields exposed by this table type.
    fields: std.ArrayList(Field),
    /// Ordered list of methods callable on instances of this table.
    methods: std.ArrayList(Function),
};

/// A single parameter in a function signature.
pub const Parameter = struct {
    /// Parameter name used in the Lua stub (e.g. `"x"`, `"self"`, `"..."`).
    name: []const u8,
    /// Human-readable description of the parameter's purpose.
    description: []const u8,
    /// Lua annotation type string (e.g. `"string"`, `"integer"`, `"any"`).
    type: []const u8,
};

/// Doc node for a function stub.
///
/// Emitted as an `---@param` / `---@return` annotated Lua function.
pub const Function = struct {
    /// Function name (e.g. `"add"`, `"open"`).
    name: []const u8,
    /// Human-readable description of what the function does.
    description: []const u8,
    /// Ordered list of parameters accepted by the function.
    parameters: std.ArrayList(Parameter),
    /// Ordered list of return value type strings.
    returns: std.ArrayList([]const u8),
};

/// A single variant entry inside an `---@alias` stanza.
pub const AliasValue = struct {
    /// Lua type string for this variant (e.g. `"'red'"`, `"{ tag = MyClass }"`).
    type: []const u8,
    /// Human-readable description of this particular variant.
    description: []const u8,
};

/// Doc node for a tagged union or enum alias.
///
/// Emitted as an `---@alias` with `---|` lines for each variant.
pub const Alias = struct {
    /// Alias name used in the Lua type system.
    name: []const u8,
    /// Human-readable description of the aliased type.
    description: []const u8,
    /// Ordered list of variant values belonging to this alias.
    values: std.ArrayList(AliasValue),
};

/// Doc node for a type with object or pointer strategy.
///
/// Objects have no `---@field` annotations; only `---@class` and method stubs
/// are emitted. The type is opaque from Lua's perspective.
pub const Object = struct {
    /// Lua class name of the opaque object.
    name: []const u8,
    /// Human-readable description of the object's purpose.
    description: []const u8,
    /// Ordered list of methods callable on instances of this object.
    methods: std.ArrayList(Function),
};

/// A tagged union that represents any single doc entry in the generator cache.
pub const Doc = union(DocKind) {
    /// A table-strategy type with fields and methods.
    Table: Table,
    /// A standalone function with parameters and returns.
    Function: Function,
    /// An opaque object or pointer-strategy type with methods.
    Object: Object,
    /// A type alias with variant values.
    Alias: Alias,
    /// A temporary sentinel inserted during collection to prevent duplicate work.
    PlaceHolder: struct {
        name: []const u8,
        description: []const u8,
    },
};
