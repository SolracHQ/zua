//! Type-walking and doc-building functions.
//!
//! This module is responsible for introspecting Zig types at comptime and
//! populating `Doc` values (tables, functions, objects, aliases) into the
//! docs cache. It is the "collection" phase of the two-phase collect-and-emit
//! pipeline.

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
const emit = @import("emit.zig");

/// Adds every field of a struct literal to the docs cache.
///
/// `module` must be a struct-like value (not a tuple). Each field is forwarded
/// to `Docs.add` which dispatches based on the field type.
///
/// Arguments:
/// - self: The docs generator to populate.
/// - module: A struct literal whose fields are types, functions, or wrappers.
pub fn addModuleValues(self: *Docs, module: anytype) anyerror!void {
    const ModuleType = @TypeOf(module);
    if (comptime @typeInfo(ModuleType) != .@"struct" and !@typeInfo(ModuleType).@"struct".is_tuple) {
        @compileError("Docs.generate and Docs.generateModule expect a struct-like module literal");
    }
    inline for (@typeInfo(ModuleType).@"struct".fields) |field| {
        try self.add(@field(module, field.name));
    }
}

/// Walks a Zig type and inserts a corresponding `Doc` entry into the cache.
///
/// Handles struct, union, enum, and opaque types according to their Zua
/// translation strategy (table, object, ptr, capture). Nested types are
/// recursed into when `recurse_nested` is true.
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
    if (!try helpers.insertPlaceholderIfNeeded(self, cache_key, Meta.nameOf(Normalized), Meta.descriptionOf(Normalized))) return;

    if (comptime helpers.shouldEmitAlias(Normalized)) {
        var doc = Alias{
            .name = try helpers.persist(self, Meta.nameOf(Normalized)),
            .description = try helpers.persist(self, Meta.descriptionOf(Normalized)),
            .values = .empty,
        };
        try collectAliasValues(self, &doc, Normalized, recurse_nested);
        try self.cache.put(cache_key, .{ .Alias = doc });
        return;
    }

    switch (Meta.strategyOf(Normalized)) {
        .table => {
            var doc = Table{
                .name = try helpers.persist(self, Meta.nameOf(Normalized)),
                .description = try helpers.persist(self, Meta.descriptionOf(Normalized)),
                .fields = .empty,
                .methods = .empty,
            };

            try collectTableFields(self, &doc, Normalized, Meta.attributeDescriptionsOf(Normalized), recurse_nested);
            try collectMethods(self, &doc.methods, Meta.methodsOf(Normalized), Normalized, recurse_nested);
            try self.cache.put(cache_key, .{ .Table = doc });
        },
        .object, .ptr, .capture => {
            var doc = Object{
                .name = try helpers.persist(self, Meta.nameOf(Normalized)),
                .description = try helpers.persist(self, Meta.descriptionOf(Normalized)),
                .methods = .empty,
            };

            try collectMethods(self, &doc.methods, Meta.methodsOf(Normalized), Normalized, recurse_nested);
            try self.cache.put(cache_key, .{ .Object = doc });
        },
    }
}

/// Adds a native function wrapper to the docs cache.
///
/// Builds a `Function` doc from the wrapper's parameter metadata and return
/// type, then inserts it into the cache.
///
/// Arguments:
/// - self: The docs generator to populate.
/// - wrapper: A `NativeFn` or `Closure` wrapper value.
/// - is_method: Whether this function is a method (skips self param).
/// - owner_type: If a method, the type that owns the method.
/// - display_name: The name to use in the generated stub.
/// - cache_key: The key used for deduplication in the cache.
pub fn addWrappedFunction(
    self: *Docs,
    wrapper: anytype,
    comptime is_method: bool,
    comptime owner_type: ?type,
    display_name: []const u8,
    cache_key: []const u8,
) !void {
    const WrapperType = @TypeOf(wrapper);
    if (comptime !helpers.isNativeWrapperType(WrapperType)) {
        @compileError("Docs.addWrappedFunction expects a NativeFn/Closure wrapper");
    }

    if (!is_method and !try helpers.insertPlaceholderIfNeeded(self, cache_key, display_name, wrapper.description)) return;

    var doc = Function{
        .name = try helpers.persist(self, display_name),
        .description = try helpers.persist(self, wrapper.description),
        .parameters = .empty,
        .returns = .empty,
    };

    try collectFunctionParameters(self, &doc, wrapper, is_method, owner_type);
    try collectFunctionReturns(self, &doc, WrapperType.__ZuaNativeReturnType);

    if (!is_method) {
        try self.cache.put(cache_key, .{ .Function = doc });
    }

    try recurseFunctionTypes(self, wrapper, is_method, owner_type);
}

/// Collects the fields of a table-strategy struct or union into a `Table` doc.
///
/// Iterates the Zig type's fields at comptime, extracting field descriptions
/// from the `ZUA_META` attribute descriptions.
fn collectTableFields(
    self: *Docs,
    doc: *Table,
    comptime T: type,
    comptime attribute_descriptions: anytype,
    comptime recurse_nested: bool,
) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.is_tuple) return;

            inline for (info.fields) |field| {
                try doc.fields.append(self.arena.allocator(), .{
                    .name = try helpers.persist(self, field.name),
                    .description = try helpers.persist(self, helpers.fieldDescription(attribute_descriptions, field.name)),
                    .type = try helpers.displayTypeName(self, field.type, .field),
                });
                try maybeRecurseReferencedType(self, field.type, recurse_nested);
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

/// Collects method declarations from `ZUA_META.methods` into an array of
/// `Function` docs.
///
/// Skips fields prefixed with `__` (internal trampoline fields).
fn collectMethods(
    self: *Docs,
    methods_out: *std.ArrayList(Function),
    comptime methods: anytype,
    comptime owner_type: type,
    comptime recurse_nested: bool,
) anyerror!void {
    inline for (@typeInfo(@TypeOf(methods)).@"struct".fields) |field| {
        if (comptime std.mem.startsWith(u8, field.name, "__")) continue;
        const method_value = @field(methods, field.name);
        const wrapped = helpers.wrapMethod(method_value);
        var doc = Function{
            .name = try helpers.persist(self, field.name),
            .description = try helpers.persist(self, wrapped.description),
            .parameters = .empty,
            .returns = .empty,
        };

        try collectFunctionParameters(self, &doc, wrapped, true, owner_type);
        try collectFunctionReturns(self, &doc, @TypeOf(wrapped).__ZuaNativeReturnType);
        try methods_out.append(self.arena.allocator(), doc);

        if (recurse_nested) {
            try recurseFunctionTypes(self, wrapped, true, owner_type);
        }
    }
}

/// Extracts parameter metadata from a native wrapper and populates the
/// `Function` doc's parameter list.
///
/// Skips `*Context`, capture pointers, and self parameters (for methods).
/// Varargs parameters are annotated as `...: any`.
fn collectFunctionParameters(
    self: *Docs,
    doc: *Function,
    wrapper: anytype,
    comptime is_method: bool,
    comptime owner_type: ?type,
) !void {
    const WrapperType = @TypeOf(wrapper);
    const fn_info = WrapperType.__ZuaFnTypeInfo;
    comptime var arg_index: usize = 0;

    inline for (fn_info.params) |param| {
        const param_type = param.type orelse continue;

        if (comptime param_type == *Context) continue;
        if (comptime helpers.isCapturePointer(param_type)) continue;

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

/// Populates the return type list of a `Function` doc from the wrapper's
/// return type tuple.
fn collectFunctionReturns(self: *Docs, doc: *Function, comptime ReturnType: type) !void {
    const count = comptime helpers.typeListCount(ReturnType);
    inline for (0..count) |index| {
        try doc.returns.append(self.arena.allocator(), try helpers.displayTypeName(self, helpers.typeListAt(ReturnType, index), .return_value));
    }
}

/// Collects the variant values of a tagged union or enum into an `Alias` doc.
///
/// For enum fields, each variant is a string literal. For union fields, each
/// variant can be a named table type (with a custom variant name) or an inline
/// table shape.
fn collectAliasValues(self: *Docs, doc: *Alias, comptime T: type, comptime recurse_nested: bool) !void {
    const variant_descs = comptime Meta.variantDescriptionsOf(T);
    switch (@typeInfo(T)) {
        .@"enum" => {
            inline for (std.meta.fields(T)) |field| {
                const name = field.name;
                try doc.values.append(self.arena.allocator(), .{
                    .type = try std.fmt.allocPrint(self.arena.allocator(), "'{s}'", .{name}),
                    .description = try helpers.persist(self, ""),
                });
            }
        },
        .@"union" => |info| {
            inline for (info.fields) |field| {
                const vinfo = comptime @field(variant_descs, field.name);
                const vdesc = comptime vinfo.description orelse "";

                if (comptime vinfo.name) |variant_name| {
                    const variant_key = try helpers.persist(self, variant_name);
                    if (try helpers.insertPlaceholderIfNeeded(self, variant_key, variant_name, vdesc)) {
                        var variant_doc = Table{
                            .name = variant_key,
                            .description = try helpers.persist(self, vdesc),
                            .fields = .empty,
                            .methods = .empty,
                        };
                        try collectVariantTableFields(self, &variant_doc, field.type, vinfo.field_descriptions, recurse_nested);
                        try self.cache.put(variant_key, .{ .Table = variant_doc });
                    }
                    try doc.values.append(self.arena.allocator(), .{
                        .type = try std.fmt.allocPrint(self.arena.allocator(), "{{ {s} = {s} }}", .{ field.name, variant_name }),
                        .description = try helpers.persist(self, vdesc),
                    });
                } else {
                    const field_type_name = try helpers.displayTypeName(self, field.type, .field);
                    try doc.values.append(self.arena.allocator(), .{
                        .type = try std.fmt.allocPrint(self.arena.allocator(), "{{ {s} = {s} }}", .{ field.name, field_type_name }),
                        .description = try helpers.persist(self, vdesc),
                    });
                    try maybeRecurseReferencedType(self, field.type, recurse_nested);
                }
            }
        },
        else => {},
    }
}

/// Recursively collects doc entries for types referenced in a function's
/// parameters and return types.
fn recurseFunctionTypes(self: *Docs, wrapper: anytype, comptime is_method: bool, comptime owner_type: ?type) anyerror!void {
    const WrapperType = @TypeOf(wrapper);
    const fn_info = WrapperType.__ZuaFnTypeInfo;

    inline for (fn_info.params) |param| {
        const param_type = param.type orelse continue;
        if (comptime param_type == *Context) continue;
        if (comptime helpers.isCapturePointer(param_type)) continue;
        if (comptime is_method and owner_type != null and helpers.isSelfParam(param_type, owner_type.?)) continue;
        try maybeRecurseReferencedType(self, param_type, true);
    }

    const count = comptime helpers.typeListCount(WrapperType.__ZuaNativeReturnType);
    inline for (0..count) |index| {
        try maybeRecurseReferencedType(self, helpers.typeListAt(WrapperType.__ZuaNativeReturnType, index), true);
    }
}

/// Conditionally recurses into a type to add it to the docs cache.
///
/// Only struct, union, enum, and opaque types with `.table` strategy are
/// recursed. Pointers to these types are dereferenced first. Arrays and
/// slices are recursed into via their child type.
fn maybeRecurseReferencedType(self: *Docs, comptime T: type, comptime recurse_nested: bool) anyerror!void {
    if (!recurse_nested) return;

    const Normalized = helpers.normalizeReferencedType(T);
    if (comptime helpers.isIgnoredDocType(Normalized)) return;
    if (comptime helpers.isTypedFunctionHandle(Normalized)) return;

    if (comptime helpers.isTransparentTypedWrapper(Normalized)) {
        return maybeRecurseReferencedType(self, helpers.unwrapTransparentTypedWrapper(Normalized), recurse_nested);
    }

    switch (@typeInfo(Normalized)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            const strategy = comptime Meta.strategyOf(Normalized);
            if (comptime strategy == .table) {
                try addType(self, Normalized, true);
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and !Mapper.isStringValueType(Normalized)) {
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
///
/// Used for union variants that have a named table type with struct fields.
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
