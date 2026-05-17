//! Type-walking and doc-building functions.
//!
//! This module is responsible for introspecting Zig types at comptime and
//! populating the generator's class, object, alias, and function lists.
//! It is the "collection" phase of the two-phase collect-and-emit pipeline.

const std = @import("std");
const Generator = @import("generator.zig").Generator;
const Types = @import("types.zig");
const Table = Types.Table;
const Function = Types.Function;
const Object = Types.Object;
const Alias = Types.Alias;
const Context = @import("../context.zig");
const Mapper = @import("../mapper/api.zig");
const Internals = @import("../mapper/internals.zig");
const ShapeData = @import("../shape/shape_data.zig");
const Helpers = @import("helpers.zig");
const Introspect = @import("../introspect.zig");
const Trampoline = @import("../shape/trampoline.zig");
const Marker = @import("../marker.zig");
const Modifier = @import("../shape/modifier.zig");

/// Walks a Zig type and inserts its documentation into the generator's lists.
///
/// Handles struct, union, enum, and opaque types according to their Zua translation
/// shape. Table types go into `classes`. Object/ptr/closure types go into
/// `objects`. Tagged unions and enums go into `aliases`. Nested types are recursed
/// into when `recurse_nested` is true. Dedup maps prevent duplicate collection.
///
/// Arguments:
/// - self: The docs generator to populate.
/// - T: The Zig type to document.
/// - recurse_nested: If true, recursively collect types referenced by fields,
///   parameters, and return values.
pub fn addType(self: *Generator, comptime T: type, comptime recurse_nested: bool) anyerror!void {
    const Normalized = Helpers.normalizeRootType(T);

    if (comptime Helpers.isIgnoredDocType(Normalized)) return;
    if (comptime Helpers.isTransparentTypedWrapper(Normalized)) {
        return addType(self, Helpers.unwrapTransparentTypedWrapper(Normalized), recurse_nested);
    }
    if (comptime Helpers.isTypedFunctionHandle(Normalized)) return;

    switch (@typeInfo(Normalized)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return,
    }

    const cache_key = @typeName(Normalized);
    const meta_info = comptime ShapeData.getShape(Normalized);

    if (meta_info.DocsHook) |hook| {
        if (self.class_map.contains(cache_key)) return;
        try self.class_map.put(try Helpers.persist(self, cache_key), {});
        try hook(self);
        return;
    }

    if (comptime Helpers.shouldEmitAlias(Normalized)) {
        if (self.alias_map.contains(cache_key)) return;
        try self.alias_map.put(try Helpers.persist(self, cache_key), {});

        var doc = Alias{
            .name = try Helpers.persist(self, ShapeData.nameOf(Normalized)),
            .description = try Helpers.persist(self, ShapeData.descriptionOf(Normalized)),
            .values = .empty,
        };
        try collectAliasValues(self, &doc, Normalized, recurse_nested);
        try self.aliases.append(self.arena.allocator(), doc);
        return;
    }

    switch (ShapeData.strategyOf(Normalized)) {
        .alias, .typed_alias, .function, .default => unreachable,
        .table => {
            if (self.class_map.contains(cache_key)) return;
            try self.class_map.put(try Helpers.persist(self, cache_key), {});

            var doc = Table{
                .name = try Helpers.persist(self, ShapeData.nameOf(Normalized)),
                .description = try Helpers.persist(self, ShapeData.descriptionOf(Normalized)),
                .fields = .empty,
                .operators = .empty,
            };

            try collectTableFields(self, &doc, Normalized, ShapeData.attributeDescriptionsOf(Normalized), recurse_nested);
            try collectMethods(self, &doc.operators, ShapeData.methodsOf(Normalized), Normalized, recurse_nested);
            try self.classes.append(self.arena.allocator(), doc);
        },
        .object, .ptr => {
            if (self.object_map.contains(cache_key)) return;
            try self.object_map.put(try Helpers.persist(self, cache_key), {});

            var doc = Object{
                .name = try Helpers.persist(self, ShapeData.nameOf(Normalized)),
                .description = try Helpers.persist(self, ShapeData.descriptionOf(Normalized)),
                .fields = .empty,
                .operators = .empty,
            };

            try collectObjectFields(self, &doc, Normalized, recurse_nested);
            try collectMethods(self, &doc.operators, ShapeData.methodsOf(Normalized), Normalized, recurse_nested);
            try self.objects.append(self.arena.allocator(), doc);
        },
        .closure => {
            const trampoline_type = comptime ShapeData.getShape(Normalized);

            if (self.functions.contains(cache_key)) return;

            var doc = Function{
                .name = try Helpers.persist(self, ShapeData.nameOf(Normalized)),
                .description = try Helpers.persist(self, ShapeData.descriptionOf(Normalized)),
            };

            try collectFunctionParameters(self, &doc, trampoline_type, false, null);
            try collectFunctionReturns(self, &doc, Trampoline.nativeReturnType(trampoline_type));
            try self.functions.put(try Helpers.persist(self, cache_key), doc);
        },
    }
}

/// Adds a native function wrapper to the functions map.
///
/// Builds a `Function` doc from the wrapper's parameter metadata and return type,
/// then inserts it keyed by `cache_key`. If the key already exists, the call is a
/// no-op (dedup). The caller should directly modify the HashMap entry when appending
/// `field_of` entries to an already-registered function.
///
/// Arguments:
/// - self: The docs generator to populate.
/// - comptime T: The native function wrapper.
/// - is_method: Whether this function is a method (skips self param).
/// - owner_type: If a method, the type that owns the method.
/// - display_name: The name to use in the generated stub.
/// - cache_key: The key used for dedup and HashMap storage.
pub fn addWrappedFunction(
    self: *Generator,
    comptime T: type,
    comptime is_method: bool,
    comptime owner_type: ?type,
    display_name: []const u8,
    cache_key: []const u8,
) !void {
    const ShapeT = comptime ShapeData.getShape(T);
    if (comptime ShapeT.Strategy != .function and ShapeT.Strategy != .closure) {
        @compileError("Docs.addWrappedFunction expects a native function or closure wrapper type");
    }

    if (self.functions.contains(cache_key)) return;

    var doc = Function{
        .name = try Helpers.persist(self, display_name),
        .description = try Helpers.persist(self, Helpers.nativeFnDesc(T)),
    };

    try collectFunctionParameters(self, &doc, T, is_method, owner_type);
    try collectFunctionReturns(self, &doc, Trampoline.nativeReturnType(T));
    try self.functions.put(try Helpers.persist(self, cache_key), doc);

    try recurseFunctionTypes(self, T, is_method, owner_type);
}

/// Collects the fields of a table-strategy struct or union into a `Table` doc.
/// NativeFn wrapper fields are promoted to `field_of` function entries instead of
/// opaque `---@field` annotations.
fn collectTableFields(
    self: *Generator,
    doc: *Table,
    comptime T: type,
    comptime attribute_descriptions: anytype,
    comptime recurse_nested: bool,
) !void {
    const owner_name = doc.name;
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.is_tuple) return;

            inline for (info.fields) |field| {
                if (comptime ShapeData.isFunction(field.type)) {
                    if (self.functions.getPtr(field.name)) |existing| {
                        try existing.field_of.append(self.arena.allocator(), .{
                            .owner = try Helpers.persist(self, owner_name),
                            .field_name = try Helpers.persist(self, field.name),
                        });
                    } else {
                        var func_doc = Function{
                            .name = try Helpers.persist(self, field.name),
                            .description = try Helpers.persist(self, Helpers.nativeFnDesc(field.type)),
                            .field_of = .empty,
                        };
                        try func_doc.field_of.append(self.arena.allocator(), .{
                            .owner = try Helpers.persist(self, owner_name),
                            .field_name = try Helpers.persist(self, field.name),
                        });
                        try collectFunctionParameters(self, &func_doc, field.type, false, null);
                        try collectFunctionReturns(self, &func_doc, Trampoline.nativeReturnType(field.type));
                        try self.functions.put(try Helpers.persist(self, field.name), func_doc);
                    }
                    try maybeRecurseReferencedType(self, field.type, recurse_nested);
                } else {
                    try doc.fields.append(self.arena.allocator(), .{
                        .name = try Helpers.persist(self, field.name),
                        .description = try Helpers.persist(self, Helpers.fieldDescription(attribute_descriptions, field.name)),
                        .type = try Helpers.displayTypeName(self, field.type, .field),
                    });
                    try maybeRecurseReferencedType(self, field.type, recurse_nested);
                }
            }
        },
        .@"union" => |info| {
            inline for (info.fields) |field| {
                try doc.fields.append(self.arena.allocator(), .{
                    .name = try Helpers.persist(self, field.name),
                    .description = try Helpers.persist(self, Helpers.fieldDescription(attribute_descriptions, field.name)),
                    .type = try Helpers.displayTypeName(self, field.type, .field),
                });
                try maybeRecurseReferencedType(self, field.type, recurse_nested);
            }
        },
        else => {},
    }
}

/// Collects `Shape.Modifier.Field` and `Shape.Modifier.Value` marked fields from an object-strategy
/// type into `---@field` annotations.
fn collectObjectFields(
    self: *Generator,
    doc: *Object,
    comptime T: type,
    comptime recurse_nested: bool,
) !void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (comptime !Modifier.isFieldOrValue(field.type)) continue;

        const InnerType = comptime Modifier.innerType(field.type);
        const opts = comptime Modifier.fieldOpts(field.type);
        try doc.fields.append(self.arena.allocator(), .{
            .name = try Helpers.persist(self, field.name),
            .description = try Helpers.persist(self, opts.description),
            .type = try Helpers.displayTypeName(self, InnerType, .field),
        });
        try maybeRecurseReferencedType(self, InnerType, recurse_nested);
    }
}

/// Collects method and operator declarations from `ZUA_SHAPE.methods`.
///
/// Plain methods (no `__` prefix) are stored in the functions list with `method_of`
/// set to the owner type's name. Metamethods with known operator names are stored as
/// `Operator` entries on the owning type.
fn collectMethods(
    self: *Generator,
    operators_out: *std.ArrayList(Types.Operator),
    comptime methods: anytype,
    comptime owner_type: type,
    comptime recurse_nested: bool,
) anyerror!void {
    const owner_name = ShapeData.nameOf(owner_type);
    inline for (@typeInfo(@TypeOf(methods)).@"struct".fields) |field| {
        if (comptime std.mem.startsWith(u8, field.name, "__")) {
            const op_name = field.name[2..];
            if (comptime !isKnownOperator(op_name)) continue;

            const method_value = @field(methods, field.name);
            const wrapped = Helpers.wrapMethod(method_value);

            var tmp = Function{
                .name = "",
                .description = "",
                .parameters = .empty,
                .returns = .empty,
            };
            try collectFunctionParameters(self, &tmp, wrapped, true, owner_type);
            try collectFunctionReturns(self, &tmp, Trampoline.nativeReturnType(wrapped));

            try operators_out.append(self.arena.allocator(), .{
                .name = try Helpers.persist(self, op_name),
                .param_type = if (tmp.parameters.items.len > 0) tmp.parameters.items[0].type else null,
                .return_type = if (tmp.returns.items.len > 0) tmp.returns.items[0] else try Helpers.persist(self, "nil"),
            });

            if (recurse_nested) {
                try recurseFunctionTypes(self, wrapped, true, owner_type);
            }
            continue;
        }

        const method_key = try std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ @typeName(owner_type), field.name });
        const method_value = @field(methods, field.name);
        const wrapped = Helpers.wrapMethod(method_value);
        var doc = Function{
            .name = try Helpers.persist(self, field.name),
            .description = try Helpers.persist(self, Helpers.nativeFnDesc(wrapped)),
            .method_of = try Helpers.persist(self, owner_name),
        };

        try collectFunctionParameters(self, &doc, wrapped, true, owner_type);
        try collectFunctionReturns(self, &doc, Trampoline.nativeReturnType(wrapped));
        try self.functions.put(method_key, doc);

        if (recurse_nested) {
            try recurseFunctionTypes(self, wrapped, true, owner_type);
        }
    }
}

/// Returns true when `name` is a known Lua operator name (without the `__` prefix)
/// that LuaLS supports with `---@operator`.
fn isKnownOperator(comptime name: []const u8) bool {
    comptime {
        for (&[_][]const u8{
            "add",    "sub",  "mul", "div",  "mod",  "pow",  "unm",
            "idiv",   "band", "bor", "bxor", "bnot", "shl",  "shr",
            "concat", "len",  "eq",  "lt",   "le",   "call",
        }) |op| {
            if (std.mem.eql(u8, name, op)) return true;
        }
        return false;
    }
}

/// Extracts parameter metadata from a native wrapper and populates the `Function`
/// doc's parameter list. Skips `*Context`, capture pointers, and self parameters
/// (for methods). Varargs parameters are annotated as `...: any`.
fn collectFunctionParameters(
    self: *Generator,
    doc: *Function,
    comptime T: type,
    comptime is_method: bool,
    comptime owner_type: ?type,
) !void {
    const ShapeT = comptime ShapeData.getShape(T);
    const fn_info = Trampoline.fnTypeInfo(T);
    comptime var arg_index: usize = 0;

    inline for (fn_info.params) |param| {
        const param_type = param.type orelse continue;

        if (comptime param_type == *Context) continue;
        if (comptime Introspect.isCapturePointer(param_type)) continue;

        if (comptime is_method and owner_type != null and Helpers.isSelfParam(param_type, owner_type.?)) continue;

        const arg_info = Helpers.argDocInfo(ShapeT.args, arg_index);
        arg_index += 1;

        if (comptime param_type == Mapper.VarArgs) {
            try doc.parameters.append(self.arena.allocator(), .{
                .name = try Helpers.persist(self, "..."),
                .description = try Helpers.persist(self, arg_info.description),
                .type = try Helpers.persist(self, "any"),
            });
            continue;
        }

        try doc.parameters.append(self.arena.allocator(), .{
            .name = try Helpers.persist(self, arg_info.name),
            .description = try Helpers.persist(self, arg_info.description),
            .type = try Helpers.displayTypeName(self, param_type, .parameter),
        });
    }
}

/// Populates the return type list of a `Function` doc from the wrapper's return
/// type tuple.
fn collectFunctionReturns(self: *Generator, doc: *Function, comptime ReturnType: type) !void {
    const count = comptime Introspect.typeListCount(ReturnType);
    inline for (0..count) |index| {
        try doc.returns.append(self.arena.allocator(), try Helpers.displayTypeName(self, Introspect.typeListAt(ReturnType, index), .return_value));
    }
}

/// Collects the variant values of a tagged union or enum into an `Alias` doc.
///
/// For `StrEnum` types, each variant is a string literal. For plain enums, each
/// variant is an integer value. For union fields, each variant can be a named table
/// type (with a custom variant name) or an inline table shape. Named variant tables
/// are pushed to the classes list.
fn collectAliasValues(self: *Generator, doc: *Alias, comptime T: type, comptime recurse_nested: bool) !void {
    const variant_descs = comptime ShapeData.variantDescriptionsOf(T);
    switch (@typeInfo(T)) {
        .@"enum" => {
            const is_str_enum = comptime ShapeData.proxyTypeOf(T) == []const u8;
            inline for (std.meta.fields(T)) |field| {
                const type_str = if (comptime is_str_enum)
                    try std.fmt.allocPrint(self.arena.allocator(), "'{s}'", .{field.name})
                else
                    try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{field.value});
                try doc.values.append(self.arena.allocator(), .{
                    .type = type_str,
                    .description = try Helpers.persist(self, ""),
                });
            }
        },
        .@"union" => |info| {
            inline for (info.fields) |field| {
                const vinfo = comptime @field(variant_descs, field.name);
                const vdesc = comptime vinfo.description orelse "";

                if (comptime vinfo.name) |variant_name| {
                    if (!self.class_map.contains(variant_name)) {
                        try self.class_map.put(try Helpers.persist(self, variant_name), {});
                        var variant_doc = Table{
                            .name = try Helpers.persist(self, variant_name),
                            .description = try Helpers.persist(self, vdesc),
                            .fields = .empty,
                            .operators = .empty,
                        };
                        try collectVariantTableFields(self, &variant_doc, field.type, vinfo.field_descriptions, recurse_nested);
                        try self.classes.append(self.arena.allocator(), variant_doc);
                    }
                    try doc.values.append(self.arena.allocator(), .{
                        .type = try std.fmt.allocPrint(self.arena.allocator(), "{{ {s}: {s} }}", .{ field.name, variant_name }),
                        .description = try Helpers.persist(self, vdesc),
                    });
                } else {
                    const field_type_name = try Helpers.displayTypeName(self, field.type, .field);
                    try doc.values.append(self.arena.allocator(), .{
                        .type = try std.fmt.allocPrint(self.arena.allocator(), "{{ {s}: {s} }}", .{ field.name, field_type_name }),
                        .description = try Helpers.persist(self, vdesc),
                    });
                    try maybeRecurseReferencedType(self, field.type, recurse_nested);
                }
            }
        },
        else => {},
    }
}

/// Recursively collects doc entries for types referenced in a function's parameters
/// and return Types.
fn recurseFunctionTypes(self: *Generator, comptime T: type, comptime is_method: bool, comptime owner_type: ?type) anyerror!void {
    const fn_info = Trampoline.fnTypeInfo(T);

    inline for (fn_info.params) |param| {
        const param_type = param.type orelse continue;
        if (comptime param_type == *Context) continue;
        if (comptime Introspect.isCapturePointer(param_type)) continue;
        if (comptime is_method and owner_type != null and Helpers.isSelfParam(param_type, owner_type.?)) continue;
        try maybeRecurseReferencedType(self, param_type, true);
    }

    const count = comptime Introspect.typeListCount(Trampoline.nativeReturnType(T));
    inline for (0..count) |index| {
        try maybeRecurseReferencedType(self, Introspect.typeListAt(Trampoline.nativeReturnType(T), index), true);
    }
}

/// Conditionally recurses into a type to add it to the docs lists.
///
/// Only struct, union, enum, and opaque types with `.table` / `.object` / `.ptr`
/// strategy are recursed. Pointers to these types are dereferenced first. Arrays
/// and slices are recursed into via their child type.
fn maybeRecurseReferencedType(self: *Generator, comptime T: type, comptime recurse_nested: bool) anyerror!void {
    if (!recurse_nested) return;

    if (comptime Internals.isOptional(T)) {
        return maybeRecurseReferencedType(self, Internals.optionalChild(T), recurse_nested);
    }

    if (comptime Helpers.isTransparentTypedWrapper(T)) {
        return maybeRecurseReferencedType(self, Helpers.unwrapTransparentTypedWrapper(T), recurse_nested);
    }

    if (comptime Helpers.isIgnoredDocType(T)) return;
    if (comptime Helpers.isTypedFunctionHandle(T)) return;
    if (comptime ShapeData.isFunction(T)) return;

    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            const strategy = comptime ShapeData.strategyOf(T);
            if (comptime strategy == .table or strategy == .object or strategy == .ptr or strategy == .closure) {
                try addType(self, T, true);
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and !Internals.isStringValueType(T)) {
                try maybeRecurseReferencedType(self, ptr.child, recurse_nested);
            }
        },
        .array => |array| {
            try maybeRecurseReferencedType(self, array.child, recurse_nested);
        },
        else => {},
    }
}

/// Collects the fields of a variant's inner struct into a `Table` doc.
fn collectVariantTableFields(
    self: *Generator,
    doc: *Table,
    comptime FieldType: type,
    comptime field_descs: anytype,
    comptime recurse_nested: bool,
) !void {
    switch (@typeInfo(FieldType)) {
        .@"struct" => |info| {
            if (info.is_tuple) return;
            inline for (info.fields) |f| {
                try doc.fields.append(self.arena.allocator(), .{
                    .name = try Helpers.persist(self, f.name),
                    .description = try Helpers.persist(self, Helpers.fieldDescription(field_descs, f.name)),
                    .type = try Helpers.displayTypeName(self, f.type, .field),
                });
                try maybeRecurseReferencedType(self, f.type, recurse_nested);
            }
        },
        else => {},
    }
}
