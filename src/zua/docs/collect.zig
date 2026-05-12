//! Type-walking and doc-building functions.
//!
//! This module is responsible for introspecting Zig types at comptime and
//! populating the generator's class, object, alias, and function lists.
//! It is the "collection" phase of the two-phase collect-and-emit pipeline.

const std = @import("std");
const Docs = @import("./docs.zig");
const types = @import("types.zig");
const Table = types.Table;
const Function = types.Function;
const Object = types.Object;
const Alias = types.Alias;
const AliasValue = types.AliasValue;
const Context = @import("../state/context.zig");
const Native = @import("../functions/native.zig");
const Handlers = @import("../handlers/handlers.zig");
const Mapper = @import("../mapper/mapper.zig");
const Meta = @import("../meta/meta.zig");
const helpers = @import("helpers.zig");
const introspect = @import("../introspect.zig");
const trampoline = @import("../functions/trampoline.zig");
const Marker = @import("../marker.zig");
const emit = @import("emit.zig");

/// Walks a Zig type and inserts its documentation into the generator's lists.
///
/// Handles struct, union, enum, and opaque types according to their Zua translation
/// strategy. Table-strategy types go into `classes`. Object/ptr/capture types go into
/// `objects`. Tagged unions and enums go into `aliases`. Nested types are recursed
/// into when `recurse_nested` is true. Dedup maps prevent duplicate collection.
///
/// Arguments:
/// - self: The docs generator to populate.
/// - T: The Zig type to document.
/// - recurse_nested: If true, recursively collect types referenced by fields,
///   parameters, and return values.
pub fn addType(self: *Docs, comptime T: type, comptime recurse_nested: bool) anyerror!void {
    const Normalized = helpers.normalizeRootType(T);

    if (comptime helpers.isIgnoredDocType(Normalized)) return;
    if (comptime helpers.isTransparentTypedWrapper(Normalized)) {
        return addType(self, helpers.unwrapTransparentTypedWrapper(Normalized), recurse_nested);
    }
    if (comptime helpers.isTypedFunctionHandle(Normalized)) return;

    switch (@typeInfo(Normalized)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return,
    }

    const cache_key = @typeName(Normalized);
    const meta_info = comptime Meta.getMeta(Normalized);

    if (meta_info.DocsHook) |hook| {
        if (self.class_map.contains(cache_key)) return;
        try self.class_map.put(try helpers.persist(self, cache_key), {});
        try hook(self);
        return;
    }

    if (comptime helpers.shouldEmitAlias(Normalized)) {
        if (self.alias_map.contains(cache_key)) return;
        try self.alias_map.put(try helpers.persist(self, cache_key), {});

        var doc = Alias{
            .name = try helpers.persist(self, Meta.nameOf(Normalized)),
            .description = try helpers.persist(self, Meta.descriptionOf(Normalized)),
            .values = .empty,
        };
        try collectAliasValues(self, &doc, Normalized, recurse_nested);
        try self.aliases.append(self.arena.allocator(), doc);
        return;
    }

    switch (Meta.strategyOf(Normalized)) {
        .table => {
            if (self.class_map.contains(cache_key)) return;
            try self.class_map.put(try helpers.persist(self, cache_key), {});

            var doc = Table{
                .name = try helpers.persist(self, Meta.nameOf(Normalized)),
                .description = try helpers.persist(self, Meta.descriptionOf(Normalized)),
                .fields = .empty,
                .operators = .empty,
            };

            try collectTableFields(self, &doc, Normalized, Meta.attributeDescriptionsOf(Normalized), recurse_nested);
            try collectMethods(self, &doc.operators, Meta.methodsOf(Normalized), Normalized, recurse_nested);
            try self.classes.append(self.arena.allocator(), doc);
        },
        .object, .ptr, .capture => {
            if (self.object_map.contains(cache_key)) return;
            try self.object_map.put(try helpers.persist(self, cache_key), {});

            var doc = Object{
                .name = try helpers.persist(self, Meta.nameOf(Normalized)),
                .description = try helpers.persist(self, Meta.descriptionOf(Normalized)),
                .operators = .empty,
            };

            try collectMethods(self, &doc.operators, Meta.methodsOf(Normalized), Normalized, recurse_nested);
            try self.objects.append(self.arena.allocator(), doc);
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
/// - wrapper: A `NativeFn` or `Closure` wrapper value.
/// - is_method: Whether this function is a method (skips self param).
/// - owner_type: If a method, the type that owns the method.
/// - display_name: The name to use in the generated stub.
/// - cache_key: The key used for dedup and HashMap storage.
pub fn addWrappedFunction(
    self: *Docs,
    wrapper: anytype,
    comptime is_method: bool,
    comptime owner_type: ?type,
    display_name: []const u8,
    cache_key: []const u8,
) !void {
    const WrapperType = @TypeOf(wrapper);
    if (comptime !Marker.isNativeFunction(WrapperType)) {
        @compileError("Docs.addWrappedFunction expects a NativeFn/Closure wrapper");
    }

    if (self.functions.contains(cache_key)) return;

    var doc = Function{
        .name = try helpers.persist(self, display_name),
        .description = try helpers.persist(self, wrapper.description),
    };

    try collectFunctionParameters(self, &doc, wrapper, is_method, owner_type);
    try collectFunctionReturns(self, &doc, trampoline.nativeReturnType(WrapperType));
    try self.functions.put(try helpers.persist(self, cache_key), doc);

    try recurseFunctionTypes(self, wrapper, is_method, owner_type);
}

/// Collects the fields of a table-strategy struct or union into a `Table` doc.
/// NativeFn wrapper fields are promoted to `field_of` function entries instead of
/// opaque `---@field` annotations.
fn collectTableFields(
    self: *Docs,
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
                if (comptime Marker.isNativeFunction(field.type)) {
                    const wrapper: field.type = .{};
                    if (self.functions.getPtr(field.name)) |existing| {
                        try existing.field_of.append(self.arena.allocator(), .{
                            .owner = try helpers.persist(self, owner_name),
                            .field_name = try helpers.persist(self, field.name),
                        });
                    } else {
                        var func_doc = Function{
                            .name = try helpers.persist(self, field.name),
                            .description = try helpers.persist(self, wrapper.description),
                            .field_of = .empty,
                        };
                        try func_doc.field_of.append(self.arena.allocator(), .{
                            .owner = try helpers.persist(self, owner_name),
                            .field_name = try helpers.persist(self, field.name),
                        });
                        try collectFunctionParameters(self, &func_doc, wrapper, false, null);
                        try collectFunctionReturns(self, &func_doc, trampoline.nativeReturnType(field.type));
                        try self.functions.put(try helpers.persist(self, field.name), func_doc);
                    }
                    try maybeRecurseReferencedType(self, field.type, recurse_nested);
                } else {
                    try doc.fields.append(self.arena.allocator(), .{
                        .name = try helpers.persist(self, field.name),
                        .description = try helpers.persist(self, helpers.fieldDescription(attribute_descriptions, field.name)),
                        .type = try helpers.displayTypeName(self, field.type, .field),
                    });
                    try maybeRecurseReferencedType(self, field.type, recurse_nested);
                }
            }
        },
        .@"union" => |info| {
            inline for (info.fields) |field| {
                try doc.fields.append(self.arena.allocator(), .{
                    .name = try helpers.persist(self, field.name),
                    .description = try helpers.persist(self, helpers.fieldDescription(attribute_descriptions, field.name)),
                    .type = try helpers.displayTypeName(self, field.type, .field),
                });
                try maybeRecurseReferencedType(self, field.type, recurse_nested);
            }
        },
        else => {},
    }
}

/// Collects method and operator declarations from `ZUA_META.methods`.
///
/// Plain methods (no `__` prefix) are stored in the functions list with `method_of`
/// set to the owner type's name. Metamethods with known operator names are stored as
/// `Operator` entries on the owning type.
fn collectMethods(
    self: *Docs,
    operators_out: *std.ArrayList(types.Operator),
    comptime methods: anytype,
    comptime owner_type: type,
    comptime recurse_nested: bool,
) anyerror!void {
    const owner_name = Meta.nameOf(owner_type);
    inline for (@typeInfo(@TypeOf(methods)).@"struct".fields) |field| {
        if (comptime std.mem.startsWith(u8, field.name, "__")) {
            const op_name = field.name[2..];
            if (comptime !isKnownOperator(op_name)) continue;

            const method_value = @field(methods, field.name);
            const wrapped = helpers.wrapMethod(method_value);

            var tmp = Function{
                .name = "",
                .description = "",
                .parameters = .empty,
                .returns = .empty,
            };
            try collectFunctionParameters(self, &tmp, wrapped, true, owner_type);
            try collectFunctionReturns(self, &tmp, trampoline.nativeReturnType(@TypeOf(wrapped)));

            try operators_out.append(self.arena.allocator(), .{
                .name = try helpers.persist(self, op_name),
                .param_type = if (tmp.parameters.items.len > 0) tmp.parameters.items[0].type else null,
                .return_type = if (tmp.returns.items.len > 0) tmp.returns.items[0] else try helpers.persist(self, "nil"),
            });

            if (recurse_nested) {
                try recurseFunctionTypes(self, wrapped, true, owner_type);
            }
            continue;
        }

        const method_key = try std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ @typeName(owner_type), field.name });
        const method_value = @field(methods, field.name);
        const wrapped = helpers.wrapMethod(method_value);
        var doc = Function{
            .name = try helpers.persist(self, field.name),
            .description = try helpers.persist(self, wrapped.description),
            .method_of = try helpers.persist(self, owner_name),
        };

        try collectFunctionParameters(self, &doc, wrapped, true, owner_type);
        try collectFunctionReturns(self, &doc, trampoline.nativeReturnType(@TypeOf(wrapped)));
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
            "add", "sub", "mul", "div", "mod", "pow", "unm",
            "idiv", "band", "bor", "bxor", "bnot", "shl", "shr",
            "concat", "len", "eq", "lt", "le",
            "call",
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
    self: *Docs,
    doc: *Function,
    wrapper: anytype,
    comptime is_method: bool,
    comptime owner_type: ?type,
) !void {
    const WrapperType = @TypeOf(wrapper);
    const fn_info = trampoline.fnTypeInfo(WrapperType);
    comptime var arg_index: usize = 0;

    inline for (fn_info.params) |param| {
        const param_type = param.type orelse continue;

        if (comptime param_type == *Context) continue;
        if (comptime introspect.isCapturePointer(param_type)) continue;

        if (comptime is_method and owner_type != null and helpers.isSelfParam(param_type, owner_type.?)) continue;

        const arg_info = helpers.argDocInfo(wrapper.args, arg_index);
        arg_index += 1;

        if (comptime param_type == Mapper.Decoder.VarArgs) {
            try doc.parameters.append(self.arena.allocator(), .{
                .name = try helpers.persist(self, "..."),
                .description = try helpers.persist(self, arg_info.description),
                .type = try helpers.persist(self, "any"),
            });
            continue;
        }

        try doc.parameters.append(self.arena.allocator(), .{
            .name = try helpers.persist(self, arg_info.name),
            .description = try helpers.persist(self, arg_info.description),
            .type = try helpers.displayTypeName(self, param_type, .parameter),
        });
    }
}

/// Populates the return type list of a `Function` doc from the wrapper's return
/// type tuple.
fn collectFunctionReturns(self: *Docs, doc: *Function, comptime ReturnType: type) !void {
    const count = comptime introspect.typeListCount(ReturnType);
    inline for (0..count) |index| {
        try doc.returns.append(self.arena.allocator(), try helpers.displayTypeName(self, introspect.typeListAt(ReturnType, index), .return_value));
    }
}

/// Collects the variant values of a tagged union or enum into an `Alias` doc.
///
/// For `strEnum` types, each variant is a string literal. For plain enums, each
/// variant is an integer value. For union fields, each variant can be a named table
/// type (with a custom variant name) or an inline table shape. Named variant tables
/// are pushed to the classes list.
fn collectAliasValues(self: *Docs, doc: *Alias, comptime T: type, comptime recurse_nested: bool) !void {
    const variant_descs = comptime Meta.variantDescriptionsOf(T);
    switch (@typeInfo(T)) {
        .@"enum" => {
            const is_str_enum = comptime Meta.proxyTypeOf(T) == []const u8;
            inline for (std.meta.fields(T)) |field| {
                const type_str = if (comptime is_str_enum)
                    try std.fmt.allocPrint(self.arena.allocator(), "'{s}'", .{field.name})
                else
                    try std.fmt.allocPrint(self.arena.allocator(), "{d}", .{field.value});
                try doc.values.append(self.arena.allocator(), .{
                    .type = type_str,
                    .description = try helpers.persist(self, ""),
                });
            }
        },
        .@"union" => |info| {
            inline for (info.fields) |field| {
                const vinfo = comptime @field(variant_descs, field.name);
                const vdesc = comptime vinfo.description orelse "";

                if (comptime vinfo.name) |variant_name| {
                    if (!self.class_map.contains(variant_name)) {
                        try self.class_map.put(try helpers.persist(self, variant_name), {});
                        var variant_doc = Table{
                            .name = try helpers.persist(self, variant_name),
                            .description = try helpers.persist(self, vdesc),
                            .fields = .empty,
                            .operators = .empty,
                        };
                        try collectVariantTableFields(self, &variant_doc, field.type, vinfo.field_descriptions, recurse_nested);
                        try self.classes.append(self.arena.allocator(), variant_doc);
                    }
                    try doc.values.append(self.arena.allocator(), .{
                        .type = try std.fmt.allocPrint(self.arena.allocator(), "{{ {s}: {s} }}", .{ field.name, variant_name }),
                        .description = try helpers.persist(self, vdesc),
                    });
                } else {
                    const field_type_name = try helpers.displayTypeName(self, field.type, .field);
                    try doc.values.append(self.arena.allocator(), .{
                        .type = try std.fmt.allocPrint(self.arena.allocator(), "{{ {s}: {s} }}", .{ field.name, field_type_name }),
                        .description = try helpers.persist(self, vdesc),
                    });
                    try maybeRecurseReferencedType(self, field.type, recurse_nested);
                }
            }
        },
        else => {},
    }
}

/// Recursively collects doc entries for types referenced in a function's parameters
/// and return types.
fn recurseFunctionTypes(self: *Docs, wrapper: anytype, comptime is_method: bool, comptime owner_type: ?type) anyerror!void {
    const WrapperType = @TypeOf(wrapper);
    const fn_info = trampoline.fnTypeInfo(WrapperType);

    inline for (fn_info.params) |param| {
        const param_type = param.type orelse continue;
        if (comptime param_type == *Context) continue;
        if (comptime introspect.isCapturePointer(param_type)) continue;
        if (comptime is_method and owner_type != null and helpers.isSelfParam(param_type, owner_type.?)) continue;
        try maybeRecurseReferencedType(self, param_type, true);
    }

    const count = comptime introspect.typeListCount(trampoline.nativeReturnType(WrapperType));
    inline for (0..count) |index| {
        try maybeRecurseReferencedType(self, introspect.typeListAt(trampoline.nativeReturnType(WrapperType), index), true);
    }
}

/// Conditionally recurses into a type to add it to the docs lists.
///
/// Only struct, union, enum, and opaque types with `.table` / `.object` / `.ptr`
/// strategy are recursed. Pointers to these types are dereferenced first. Arrays
/// and slices are recursed into via their child type.
fn maybeRecurseReferencedType(self: *Docs, comptime T: type, comptime recurse_nested: bool) anyerror!void {
    if (!recurse_nested) return;

    if (comptime Mapper.isOptional(T)) {
        return maybeRecurseReferencedType(self, Mapper.optionalChild(T), recurse_nested);
    }

    if (comptime helpers.isTransparentTypedWrapper(T)) {
        return maybeRecurseReferencedType(self, helpers.unwrapTransparentTypedWrapper(T), recurse_nested);
    }

    if (comptime helpers.isIgnoredDocType(T)) return;
    if (comptime helpers.isTypedFunctionHandle(T)) return;
    if (comptime Marker.isNativeFunction(T)) return;

    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            const strategy = comptime Meta.strategyOf(T);
            if (comptime strategy == .table or strategy == .object or strategy == .ptr) {
                try addType(self, T, true);
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and !Mapper.isStringValueType(T)) {
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
    self: *Docs,
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
                    .name = try helpers.persist(self, f.name),
                    .description = try helpers.persist(self, helpers.fieldDescription(field_descs, f.name)),
                    .type = try helpers.displayTypeName(self, f.type, .field),
                });
                try maybeRecurseReferencedType(self, f.type, recurse_nested);
            }
        },
        else => {},
    }
}
