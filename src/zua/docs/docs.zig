//! Lua stub generator for editor and language-server support.
//!
//! `Docs` walks the same metadata and wrapper surface used by the runtime
//! encoder and produces Lua annotation stubs for exposed functions, table
//! strategy types, and object methods. The generated output is intended for
//! tooling such as Lua language servers, not for runtime execution.

pub const Docs = @This();

const std = @import("std");
const Context = @import("../state/context.zig");
const Native = @import("../functions/native.zig");
const Handlers = @import("../handlers/handlers.zig");
const RawFunction = @import("../handlers/function.zig").Function;
const RawTable = @import("../handlers/table.zig").Table;
const RawUserdata = @import("../handlers/userdata.zig").Userdata;
const Mapper = @import("../mapper/mapper.zig");
const Meta = @import("../meta.zig");

const DocKind = enum {
    Table,
    Function,
    Object,
    PlaceHolder,
};

const DisplayContext = enum {
    field,
    parameter,
    return_value,
};

const Field = struct {
    name: []const u8,
    description: []const u8,
    type: []const u8,
};

const Table = struct {
    name: []const u8,
    description: []const u8,
    fields: std.ArrayList(Field),
    methods: std.ArrayList(Function),
};

const Parameter = struct {
    name: []const u8,
    description: []const u8,
    type: []const u8,
};

const Function = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.ArrayList(Parameter),
    returns: std.ArrayList([]const u8),
};

/// Type with opaque userdata or pointer strategy documentation.
const Object = struct {
    name: []const u8,
    description: []const u8,
    methods: std.ArrayList(Function),
};

pub const Doc = union(DocKind) {
    Table: Table,
    Function: Function,
    Object: Object,
    PlaceHolder: struct {
        name: []const u8,
        description: []const u8,
    },
};

cache: std.StringHashMap(Doc),
arena: std.heap.ArenaAllocator,
heap: std.mem.Allocator,

/// Creates a new stub generator using `allocator` for its cache and arena.
///
/// Generated strings and intermediate docs are stored in the internal arena
/// and released together in `deinit`.
pub fn init(allocator: std.mem.Allocator) Docs {
    return Docs{
        .cache = std.StringHashMap(Doc).init(allocator),
        .arena = std.heap.ArenaAllocator.init(allocator),
        .heap = allocator,
    };
}

/// Releases all memory owned by the generator.
pub fn deinit(self: *Docs) void {
    self.cache.deinit();
    self.arena.deinit();
}

/// Adds a type, native wrapper, or plain Zig function to the docs cache.
///
/// Plain Zig functions are documented as `NativeFn(function, .{})`, mirroring
/// the encoder behavior when they are pushed into Lua.
///
/// Repeated additions of the same type or function are ignored after the first
/// cached entry is created.
pub fn add(self: *Docs, item: anytype) !void {
    const ItemType = @TypeOf(item);

    if (ItemType == type) {
        const T = normalizeRootType(item);
        if (comptime isNativeWrapperType(T)) {
            return self.addWrappedFunction(T{}, false, null, T.name, T.name);
        }
        if (comptime isTypedFunctionHandle(T)) return;
        return self.addType(T, true);
    }

    if (comptime @typeInfo(ItemType) == .@"fn") {
        const wrapped = Native.new(item, .{});
        return self.addWrappedFunction(wrapped, false, null, wrapped.name, wrapped.name);
    }

    if (comptime isNativeWrapperType(ItemType)) {
        return self.addWrappedFunction(item, false, null, item.name, item.name);
    }

    return self.addType(normalizeRootType(ItemType), true);
}

/// Generates Lua stub text for all collected docs.
///
/// The returned slice is arena-backed and remains valid until `deinit`.
pub fn generate(self: *Docs) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    var it = self.cache.iterator();
    var first = true;

    while (it.next()) |entry| {
        switch (entry.value_ptr.*) {
            .PlaceHolder => continue,
            .Table => |doc| {
                if (!first) try out.appendSlice(self.arena.allocator(), "\n");
                first = false;
                try emitTableStub(self.arena.allocator(), &out, doc);
            },
            .Function => |doc| {
                if (!first) try out.appendSlice(self.arena.allocator(), "\n");
                first = false;
                try emitFunctionStub(self.arena.allocator(), &out, doc, null);
            },
            .Object => |doc| {
                if (!first) try out.appendSlice(self.arena.allocator(), "\n");
                first = false;
                try emitObjectStub(self.arena.allocator(), &out, doc);
            },
        }
    }

    return out.toOwnedSlice(self.arena.allocator());
}

fn addType(self: *Docs, comptime T: type, comptime recurse_nested: bool) anyerror!void {
    const Normalized = normalizeRootType(T);

    if (comptime isIgnoredDocType(Normalized)) return;
    if (comptime isTransparentTypedWrapper(Normalized)) {
        return self.addType(unwrapTransparentTypedWrapper(Normalized), recurse_nested);
    }
    if (comptime isTypedFunctionHandle(Normalized)) return;

    switch (@typeInfo(Normalized)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return,
    }

    const meta = comptime Meta.getMeta(Normalized);
    const cache_key = @typeName(Normalized);
    if (!try self.insertPlaceholderIfNeeded(cache_key, meta.name, meta.description)) return;

    switch (meta.strategy) {
        .table => {
            var doc = Table{
                .name = try self.persist(meta.name),
                .description = try self.persist(meta.description),
                .fields = .empty,
                .methods = .empty,
            };

            try self.collectTableFields(&doc, Normalized, meta.attributeDescriptions, recurse_nested);
            try self.collectMethods(&doc.methods, meta.methods, Normalized, recurse_nested);
            try self.cache.put(cache_key, .{ .Table = doc });
        },
        .object, .ptr, .capture => {
            var doc = Object{
                .name = try self.persist(meta.name),
                .description = try self.persist(meta.description),
                .methods = .empty,
            };

            try self.collectMethods(&doc.methods, meta.methods, Normalized, recurse_nested);
            try self.cache.put(cache_key, .{ .Object = doc });
        },
    }
}

fn addWrappedFunction(
    self: *Docs,
    wrapper: anytype,
    comptime is_method: bool,
    comptime owner_type: ?type,
    display_name: []const u8,
    cache_key: []const u8,
) !void {
    const WrapperType = @TypeOf(wrapper);
    if (comptime !isNativeWrapperType(WrapperType)) {
        @compileError("Docs.addWrappedFunction expects a NativeFn/Closure wrapper");
    }

    if (!is_method and !try self.insertPlaceholderIfNeeded(cache_key, display_name, wrapper.description)) return;

    var doc = Function{
        .name = try self.persist(display_name),
        .description = try self.persist(wrapper.description),
        .parameters = .empty,
        .returns = .empty,
    };

    try self.collectFunctionParameters(&doc, wrapper, is_method, owner_type);
    try self.collectFunctionReturns(&doc, WrapperType.__ZuaFnReturnType);

    if (!is_method) {
        try self.cache.put(cache_key, .{ .Function = doc });
    }
}

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
                    .name = try self.persist(field.name),
                    .description = try self.persist(fieldDescription(attribute_descriptions, field.name)),
                    .type = try self.displayTypeName(field.type, .field),
                });
                try self.maybeRecurseReferencedType(field.type, recurse_nested);
            }
        },
        .@"union" => |info| {
            inline for (info.fields) |field| {
                try doc.fields.append(self.arena.allocator(), .{
                    .name = try self.persist(field.name),
                    .description = try self.persist(fieldDescription(attribute_descriptions, field.name)),
                    .type = try self.displayTypeName(field.type, .field),
                });
                try self.maybeRecurseReferencedType(field.type, recurse_nested);
            }
        },
        else => {},
    }
}

fn collectMethods(
    self: *Docs,
    methods_out: *std.ArrayList(Function),
    comptime methods: anytype,
    comptime owner_type: type,
    comptime recurse_nested: bool,
) anyerror!void {
    inline for (@typeInfo(@TypeOf(methods)).@"struct".fields) |field| {
        const method_value = @field(methods, field.name);
        const wrapped = wrapMethod(method_value);
        var doc = Function{
            .name = try self.persist(field.name),
            .description = try self.persist(wrapped.description),
            .parameters = .empty,
            .returns = .empty,
        };

        try self.collectFunctionParameters(&doc, wrapped, true, owner_type);
        try self.collectFunctionReturns(&doc, @TypeOf(wrapped).__ZuaFnReturnType);
        try methods_out.append(self.arena.allocator(), doc);

        if (recurse_nested) {
            try self.recurseFunctionTypes(wrapped, true, owner_type);
        }
    }
}

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
        if (comptime isCaptureParam(param_type)) continue;

        if (comptime is_method and owner_type != null and isSelfParam(param_type, owner_type.?)) continue;

        const arg_info = argDocInfo(wrapper.args, arg_index);
        arg_index += 1;

        try doc.parameters.append(self.arena.allocator(), .{
            .name = try self.persist(arg_info.name),
            .description = try self.persist(arg_info.description),
            .type = try self.displayTypeName(param_type, .parameter),
        });
    }
}

fn collectFunctionReturns(self: *Docs, doc: *Function, comptime ReturnType: type) !void {
    const count = comptime typeListCount(ReturnType);
    inline for (0..count) |index| {
        try doc.returns.append(self.arena.allocator(), try self.displayTypeName(typeListAt(ReturnType, index), .return_value));
    }
}

fn recurseFunctionTypes(self: *Docs, wrapper: anytype, comptime is_method: bool, comptime owner_type: ?type) anyerror!void {
    const WrapperType = @TypeOf(wrapper);
    const fn_info = WrapperType.__ZuaFnTypeInfo;

    inline for (fn_info.params) |param| {
        const param_type = param.type orelse continue;
        if (comptime param_type == *Context) continue;
        if (comptime isCaptureParam(param_type)) continue;
        if (comptime is_method and owner_type != null and isSelfParam(param_type, owner_type.?)) continue;
        try self.maybeRecurseReferencedType(param_type, true);
    }

    const count = comptime typeListCount(WrapperType.__ZuaFnReturnType);
    inline for (0..count) |index| {
        try self.maybeRecurseReferencedType(typeListAt(WrapperType.__ZuaFnReturnType, index), true);
    }
}

fn maybeRecurseReferencedType(self: *Docs, comptime T: type, comptime recurse_nested: bool) anyerror!void {
    if (!recurse_nested) return;

    const Normalized = normalizeReferencedType(T);
    if (comptime isIgnoredDocType(Normalized)) return;
    if (comptime isTypedFunctionHandle(Normalized)) return;

    if (comptime isTransparentTypedWrapper(Normalized)) {
        return self.maybeRecurseReferencedType(unwrapTransparentTypedWrapper(Normalized), recurse_nested);
    }

    switch (@typeInfo(Normalized)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {
            const strategy = Meta.getMeta(Normalized).strategy;
            if (comptime strategy == .table) {
                try self.addType(Normalized, true);
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and !Mapper.isStringValueType(Normalized)) {
                try self.maybeRecurseReferencedType(ptr.child, recurse_nested);
            }
        },
        .array => |array| {
            try self.maybeRecurseReferencedType(array.child, recurse_nested);
        },
        else => {},
    }
}

fn displayTypeName(self: *Docs, comptime T: type, comptime ctx: DisplayContext) ![]const u8 {
    const Normalized = normalizeReferencedType(T);

    if (comptime isTransparentTypedWrapper(Normalized)) {
        return self.displayTypeName(unwrapTransparentTypedWrapper(Normalized), ctx);
    }

    if (comptime isTypedFunctionHandle(Normalized)) {
        return self.functionHandleSignature(Normalized);
    }

    if (Normalized == RawTable) return self.persist("table");
    if (Normalized == RawFunction) return self.persist("function");
    if (Normalized == RawUserdata) return self.persist("userdata");
    if (Normalized == Mapper.Decoder.VarArgs) return self.persist("...");

    if (comptime @typeInfo(Normalized) == .@"fn") return self.persist("function");
    if (comptime isNativeWrapperType(Normalized)) return self.persist("function");
    if (comptime Mapper.isStringValueType(Normalized)) return self.persist("string");

    return switch (@typeInfo(Normalized)) {
        .bool => self.persist("boolean"),
        .int, .comptime_int => self.persist("integer"),
        .float, .comptime_float => self.persist("number"),
        .void => self.persist("nil"),
        .optional => |optional| self.displayTypeName(optional.child, ctx),
        .array => |array| blk: {
            const child_name = try self.displayTypeName(array.child, ctx);
            break :blk try std.fmt.allocPrint(self.arena.allocator(), "{s}[]", .{child_name});
        },
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                const child_name = try self.displayTypeName(ptr.child, ctx);
                break :blk try std.fmt.allocPrint(self.arena.allocator(), "{s}[]", .{child_name});
            }

            if (ptr.size == .one) {
                const child = ptr.child;
                if (comptime @typeInfo(child) == .@"struct" or @typeInfo(child) == .@"union" or @typeInfo(child) == .@"enum" or @typeInfo(child) == .@"opaque") {
                    break :blk try self.persist(Meta.getMeta(child).name);
                }
            }

            break :blk try self.persist(@typeName(Normalized));
        },
        .@"struct", .@"union", .@"enum", .@"opaque" => self.persist(Meta.getMeta(Normalized).name),
        else => self.persist(@typeName(Normalized)),
    };
}

fn functionHandleSignature(self: *Docs, comptime T: type) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(self.arena.allocator(), "fun(");

    const arg_count = typeListCount(T.Args);
    inline for (0..arg_count) |index| {
        if (index > 0) try out.appendSlice(self.arena.allocator(), ", ");
        const arg_name = try std.fmt.allocPrint(self.arena.allocator(), "arg{d}", .{index + 1});
        const arg_type = try self.displayTypeName(typeListAt(T.Args, index), .parameter);
        try appendFmt(self.arena.allocator(), &out, "{s}: {s}", .{ arg_name, arg_type });
    }

    try out.appendSlice(self.arena.allocator(), ")");

    const return_count = typeListCount(T.Result);
    if (return_count > 0) {
        try out.appendSlice(self.arena.allocator(), ": ");
        inline for (0..return_count) |index| {
            if (index > 0) try out.appendSlice(self.arena.allocator(), ", ");
            try out.appendSlice(self.arena.allocator(), try self.displayTypeName(typeListAt(T.Result, index), .return_value));
        }
    }

    return out.toOwnedSlice(self.arena.allocator());
}

fn emitTableStub(allocator: std.mem.Allocator, out: *std.ArrayList(u8), doc: Table) !void {
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

fn emitObjectStub(allocator: std.mem.Allocator, out: *std.ArrayList(u8), doc: Object) !void {
    try appendFmt(allocator, out, "---@class {s}\n", .{doc.name});
    if (doc.description.len > 0) try appendFmt(allocator, out, "-- {s}\n", .{doc.description});
    try appendFmt(allocator, out, "local {s} = {{}}\n", .{doc.name});

    for (doc.methods.items) |method| {
        try out.appendSlice(allocator, "\n");
        try emitFunctionStub(allocator, out, method, doc.name);
    }
}

fn emitFunctionStub(allocator: std.mem.Allocator, out: *std.ArrayList(u8), doc: Function, owner_name: ?[]const u8) !void {
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

fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    try out.appendSlice(allocator, text);
}

fn insertPlaceholderIfNeeded(self: *Docs, key: []const u8, display_name: []const u8, description: []const u8) !bool {
    if (self.cache.get(key) != null) return false;

    try self.cache.put(try self.persist(key), .{ .PlaceHolder = .{
        .name = try self.persist(display_name),
        .description = try self.persist(description),
    } });
    return true;
}

fn persist(self: *Docs, text: []const u8) ![]const u8 {
    return self.arena.allocator().dupe(u8, text);
}

fn wrapMethod(comptime method_value: anytype) @TypeOf(if (@typeInfo(@TypeOf(method_value)) == .@"fn") Native.new(method_value, .{}) else method_value) {
    const T = @TypeOf(method_value);
    if (comptime @typeInfo(T) == .@"fn") return Native.new(method_value, .{});
    if (comptime isNativeWrapperType(T)) return method_value;
    @compileError("method docs only support Zig functions or NativeFn/Closure wrappers");
}

fn normalizeRootType(comptime T: type) type {
    if (comptime isTransparentTypedWrapper(T)) return unwrapTransparentTypedWrapper(T);
    return T;
}

fn normalizeReferencedType(comptime T: type) type {
    if (comptime Mapper.isOptional(T)) return normalizeReferencedType(Mapper.optionalChild(T));
    if (comptime isTransparentTypedWrapper(T)) return unwrapTransparentTypedWrapper(T);

    return switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .one)
            switch (@typeInfo(ptr.child)) {
                .@"struct", .@"union", .@"enum", .@"opaque" => ptr.child,
                else => T,
            }
        else
            T,
        else => T,
    };
}

fn unwrapTransparentTypedWrapper(comptime T: type) type {
    if (comptime hasStructDecl(T, "__ZUA_USERDATA_TYPE")) return T.__ZUA_USERDATA_TYPE;
    if (comptime hasStructDecl(T, "__ZUA_TABLE_VIEW")) return @typeInfo(@TypeOf(@as(T, undefined).ref)).pointer.child;
    return T;
}

fn isTransparentTypedWrapper(comptime T: type) bool {
    return hasStructDecl(T, "__ZUA_USERDATA_TYPE") or hasStructDecl(T, "__ZUA_TABLE_VIEW");
}

fn isNativeWrapperType(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "__IsZuaFn");
}

fn isTypedFunctionHandle(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Args") and @hasDecl(T, "Result") and @hasField(T, "function");
}

fn isIgnoredDocType(comptime T: type) bool {
    return T == *Context or T == Context or T == Mapper.Decoder.Primitive or T == Handlers.Handle;
}

fn hasStructDecl(comptime T: type, comptime name: []const u8) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, name);
}

fn fieldDescription(comptime descriptions: anytype, comptime field_name: []const u8) []const u8 {
    inline for (@typeInfo(@TypeOf(descriptions)).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, field_name)) {
            return @field(descriptions, field.name);
        }
    }
    return "";
}

fn argDocInfo(comptime args: anytype, comptime index: usize) struct { name: []const u8, description: []const u8 } {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    if (index < fields.len) {
        const field = fields[index];
        const value = @field(args, field.name);
        const ValueType = @TypeOf(value);

        if (ValueType == Native.ArgInfo) {
            return .{
                .name = value.name,
                .description = value.description orelse "",
            };
        }

        return .{
            .name = field.name,
            .description = value,
        };
    }

    return .{
        .name = std.fmt.comptimePrint("arg{d}", .{index + 1}),
        .description = "",
    };
}

fn isCaptureParam(comptime T: type) bool {
    if (@typeInfo(T) != .pointer) return false;
    const ptr = @typeInfo(T).pointer;
    if (ptr.size != .one) return false;
    const Child = ptr.child;
    if (!(@typeInfo(Child) == .@"struct" or @typeInfo(Child) == .@"union" or @typeInfo(Child) == .@"enum")) return false;
    if (!@hasDecl(Child, "ZUA_META")) return false;
    return Child.ZUA_META.strategy == .capture;
}

fn isSelfParam(comptime ParamType: type, comptime OwnerType: type) bool {
    if (ParamType == OwnerType) return true;
    if (ParamType == RawTable or ParamType == RawUserdata) return true;
    if (comptime isTransparentTypedWrapper(ParamType)) return unwrapTransparentTypedWrapper(ParamType) == OwnerType;

    if (@typeInfo(ParamType) == .pointer and @typeInfo(ParamType).pointer.size == .one) {
        return @typeInfo(ParamType).pointer.child == OwnerType;
    }

    return false;
}

fn typeListCount(comptime spec: anytype) usize {
    const SpecType = @TypeOf(spec);
    if (SpecType == type) {
        const info = @typeInfo(spec);
        if (info == .void) return 0;
        if (info == .@"struct" and info.@"struct".is_tuple) return info.@"struct".fields.len;
        return 1;
    }
    return spec.len;
}

fn typeListAt(comptime spec: anytype, comptime index: usize) type {
    const SpecType = @TypeOf(spec);
    if (SpecType == type) {
        const info = @typeInfo(spec);
        if (info == .@"struct" and info.@"struct".is_tuple) return spec[index];
        if (index == 0) return spec;
        @compileError("typeListAt index out of bounds for non-tuple type " ++ @typeName(spec));
    }
    return spec[index];
}

test {
    std.testing.refAllDecls(@This());
}
