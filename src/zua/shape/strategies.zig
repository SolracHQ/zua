const std = @import("std");
const meta = @import("./shape.zig");
const metadata = @import("metadata.zig");
const internal = @import("./internal.zig");
const FnOpts = @import("fn.zig").FnOptions;
const ArgInfo = @import("fn.zig").ArgInfo;
const trampoline = @import("trampoline.zig");
const Context = @import("../state/context.zig");
const Mapper = @import("../mapper/mapper.zig");

/// Declare `T` as an `.object` shape.
///
/// Object types are represented as full userdata in Lua and expose
/// methods through a metatable. Use this for Zig values that need
/// identity, mutability, and controlled behavior from Lua.
///
/// Example:
/// ```zig
/// const Process = struct {
///     pub const ZUA_SHAPE = zua.Shape.Object(Process, .{
///         .__gc = cleanup,
///         .__tostring = display,
///         .getParentPid = getParentPid,
///     }, .{ .name = "Process", .description = "A system process." });
///
///     pid: std.posix.pid_t,
///     name: []const u8,
/// };
/// ```
pub inline fn Object(comptime T: type, comptime methods: anytype, comptime options: meta.MetaOptions(T, .object)) type {
    comptime internal.assertContainerType(T);
    comptime internal.assertMethodsIsStruct(methods);
    comptime internal.assertValidMethods(methods);
    return comptime metadata.MetaData(T, void, .object, null, null, methods, options, null);
}

/// Declare `T` as a `.table` shape.
///
/// Table types are represented as Lua tables with fields mapped from
/// Zig struct members or union variants. This is the default shape.
///
/// Example:
/// ```zig
/// const Point = struct {
///     pub const ZUA_SHAPE = zua.Shape.Table(Point, .{}, .{
///         .name = "Point",
///         .field_descriptions = .{
///             .x = "Horizontal coordinate",
///             .y = "Vertical coordinate",
///         },
///     });
///     x: i32,
///     y: i32,
/// };
/// ```
pub inline fn Table(comptime T: type, comptime methods: anytype, comptime options: meta.MetaOptions(T, .table)) type {
    comptime internal.assertContainerType(T);
    comptime internal.assertTaggedIfUnion(T);
    comptime internal.assertMethodsIsStruct(methods);
    comptime internal.assertValidMethods(methods);
    return comptime metadata.MetaData(T, void, .table, null, null, methods, options, null);
}

/// Declare `T` as a `.ptr` shape.
///
/// Ptr types are represented as Lua light userdata, with no metatable or
/// field access. Use this for opaque handles that Lua should not inspect.
pub inline fn Ptr(comptime T: type, comptime options: meta.MetaOptions(T, .ptr)) type {
    comptime internal.assertContainerType(T);
    return comptime metadata.MetaData(T, void, .ptr, null, null, null, options, null);
}

/// Declare `T` as a callable closure shape.
///
/// The struct is stored as the closure's captured state. Each call from
/// Lua invokes `callback` with `*T` as the first parameter (or second
/// if `*Context` comes first). Remaining parameters are decoded from Lua.
///
/// Arguments:
/// - T: The struct type that holds the closure state.
/// - callback: A function `fn (*T, args...)` or `fn (*Context, *T, args...)`.
/// - gc: Optional cleanup. Pass `null` or `void` for none, or a
///       `fn (*Context, *T) void` that follows the normal method path.
/// - options: `FnOptions` with optional `description`, `args`.
pub inline fn Closure(comptime T: type, comptime callback: anytype, comptime gc: anytype, comptime options: FnOpts) type {
    comptime internal.assertContainerType(T);
    if (comptime @typeInfo(T) != .@"struct")
        @compileError("Closure requires a struct type, got " ++ @typeName(T));

    const gc_methods = if (gc == null or gc == void) .{} else .{ .__gc = gc };

    const trampoline_type = comptime trampoline.makeClosure(T, callback, .{ .args = options.args, .description = options.description });

    return struct {
        pub const Strategy = metadata.MappingStrategy.closure;
        pub const Proxy = void;
        pub const EncodeHook: meta.EncodeHookType(T, void) = struct {
            fn hook(_: *Context, _: T) anyerror!?void {
                return null;
            }
        }.hook;
        pub const DecodeHook: meta.DecodeHookType(T) = struct {
            fn hook(_: *Context, _: Mapper.Primitive) anyerror!?T {
                return null;
            }
        }.hook;
        pub const Methods = gc_methods;
        pub const Description: []const u8 = options.description;
        pub const Name: []const u8 = blk: {
            const full: []const u8 = @typeName(T);
            const dot = std.mem.lastIndexOfScalar(u8, full, '.');
            break :blk if (dot) |d| full[d + 1 ..] else full;
        };
        pub const AttributeDescriptions = .{};
        pub const VariantDescriptions = .{};
        pub const DocsHook: ?meta.DocsHookType(T) = null;

        pub const __ZUA_CLOSURE_TRAMPOLINE = trampoline_type;
    };
}

/// Declare `T` as a string-backed enum shape.
///
/// Sets up `T` as a `.table` type and derives encode/decode hooks so the
/// enum is pushed as a string and parsed from string values.
pub inline fn strEnum(comptime T: type, comptime methods: anytype, comptime options: meta.MetaOptions(T, .table)) type {
    if (comptime @typeInfo(T) != .@"enum")
        @compileError("strEnum requires an enum type, got " ++ @typeName(T));
    comptime internal.assertMethodsIsStruct(methods);
    comptime internal.assertValidMethods(methods);
    return comptime metadata.MetaData(T, []const u8, .table, internal.strEnumEncode(T), internal.strEnumDecode(T), methods, options, null);
}

/// Declare `T` as a list-type `.object` shape.
///
/// This builds a userdata-backed list object that supports Lua indexing,
/// length queries, and iterator semantics. The `getElements` accessor is
/// used to derive element values and implement the generated methods:
/// `get`, `__index`, `__len`, and `iter`.
///
/// User-provided `methods` are merged with the generated list methods, and
/// compile-time collisions are rejected so generated names stay stable.
///
/// `getElements` must be a comptime function taking `*T` and returning a
/// slice of element values.
///
/// Example:
/// ```zig
/// const Process = struct { /* ... */ };
/// const ProcList = struct {
///     pub const ZUA_SHAPE = zua.Shape.List(ProcList, getElements, .{
///         .__gc = deinit,
///         .__tostring = display,
///     }, .{ .name = "ProcList" });
///
///     processes: std.ArrayList(zua.Object(Process)),
/// };
///
/// fn getElements(self: *ProcList) []zua.Object(Process) {
///     return self.processes.items;
/// }
/// ```
pub inline fn List(comptime T: type, comptime getElements: anytype, comptime methods: anytype, comptime options: meta.MetaOptions(T, .object)) type {
    comptime internal.assertContainerType(T);
    comptime internal.assertMethodsIsStruct(methods);
    comptime internal.assertValidMethods(methods);
    comptime internal.assertNoListCollisions(methods);
    return comptime metadata.MetaData(T, void, .object, null, null, internal.mergeMethodSets(internal.generateListMethodsSet(T, getElements), methods), options, null);
}

test {
    std.testing.refAllDecls(@This());
}
