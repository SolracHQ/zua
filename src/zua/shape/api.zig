//! Declares how a Zig type maps to its Lua representation.
//!
//! Attach a `pub const ZUA_SHAPE` to your type using one of the
//! constructors here. Each constructor picks a strategy: table,
//! alias, typed alias, object, ptr, or closure.
//!
//! When no `ZUA_SHAPE` is present, the encoder falls back to a
//! default strategy based on the Zig type: structs become tables,
//! enums become aliases, tagged unions become typed aliases, and
//! untagged unions and opaque types become objects. Attach a shape
//! when you need to override that default or add methods and
//! lifecycle hooks.

const std = @import("std");
const Context = @import("../context.zig");

pub const Options = @import("options.zig");

pub const Internals = @import("internals.zig");

pub const EncodeHookType = Internals.Helpers.EncodeHookType;
pub const DecodeHookType = Internals.Helpers.DecodeHookType;
pub const DocsHookType = Internals.Helpers.DocsHookType;

pub const Modifier = @import("modifier.zig");

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
pub inline fn Object(comptime T: type, comptime methods: anytype, comptime opts: Options.ObjectOptions) type {
    comptime Internals.Assertions.assertContainerType(T);
    comptime Internals.Assertions.assertMethodsIsStruct(methods);
    comptime Internals.Assertions.assertValidMethods(methods);
    return comptime Internals.ShapeData.Shape(T, void, .object, null, null, methods, opts, null);
}

/// Declare `T` as a `.table` shape.
///
/// Table types are represented as Lua tables with fields mapped from
/// Zig struct members. Only struct types can use this strategy. For
/// tagged unions see `TypedAlias`, for enums see `Alias`.
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
pub inline fn Table(comptime T: type, comptime methods: anytype, comptime opts: Options.TableOptions(T)) type {
    comptime {
        if (@typeInfo(T) != .@"struct")
            @compileError(@typeName(T) ++ " must be a struct to use Table strategy");
    }
    comptime Internals.Assertions.assertMethodsIsStruct(methods);
    comptime Internals.Assertions.assertValidMethods(methods);
    return comptime Internals.ShapeData.Shape(T, void, .table, null, null, methods, opts, null);
}

/// Declare `T` as a `.ptr` shape.
///
/// Ptr types are represented as Lua light userdata, with no metatable or
/// field access. Use this for opaque handles that Lua should not inspect.
pub inline fn Ptr(comptime T: type, comptime opts: Options.PtrOptions) type {
    comptime Internals.Assertions.assertContainerType(T);
    return comptime Internals.ShapeData.Shape(T, void, .ptr, null, null, null, opts, null);
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
pub inline fn Closure(comptime T: type, comptime callback: anytype, comptime gc: anytype, comptime opts: Options.Fn) type {
    comptime Internals.Assertions.assertContainerType(T);
    if (comptime @typeInfo(T) != .@"struct")
        @compileError("Closure requires a struct type, got " ++ @typeName(T));
    return Internals.Trampoline.ShapeClosure(T, callback, gc, opts);
}

/// Declare `T` as a string-backed alias (enum with string representation).
///
/// Attaches encode and decode hooks so the enum is pushed as a Lua string
/// and parsed from string values.
///
/// Example:
/// ```zig
/// const Priority = enum {
///     pub const ZUA_SHAPE = zua.Shape.StrAlias(Priority, .{}, .{
///         .name = "Priority",
///         .description = "Task priority level.",
///     });
///     low, normal, high
/// };
/// ```
pub inline fn StrAlias(comptime T: type, comptime methods: anytype, comptime opts: Options.AliasOptions(T)) type {
    if (comptime @typeInfo(T) != .@"enum")
        @compileError("StrAlias requires an enum type, got " ++ @typeName(T));
    comptime Internals.Assertions.assertMethodsIsStruct(methods);
    comptime Internals.Assertions.assertValidMethods(methods);
    return comptime Internals.ShapeData.Shape(T, []const u8, .alias, Internals.Helpers.strEnumEncode(T), Internals.Helpers.strEnumDecode(T), methods, opts, null);
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
pub inline fn List(comptime T: type, comptime getElements: anytype, comptime methods: anytype, comptime opts: Options.ObjectOptions) type {
    comptime Internals.Assertions.assertContainerType(T);
    comptime Internals.Assertions.assertMethodsIsStruct(methods);
    comptime Internals.Assertions.assertValidMethods(methods);
    comptime Internals.Assertions.assertNoListCollisions(methods);
    return comptime Internals.ShapeData.Shape(T, void, .object, null, null, Internals.Helpers.mergeMethodSets(Internals.Helpers.generateListMethodsSet(T, getElements), methods), opts, null);
}

/// Declare `T` as an alias (enum with integer representation).
///
/// This is the default shape for enums. Each variant maps to its integer
/// tag value. Use `StrAlias` to push enums as strings instead.
///
/// Example:
/// ```zig
/// const Color = enum { red, green, blue };
/// const MyColor = enum {
///     pub const ZUA_SHAPE = zua.Shape.Alias(MyColor, .{}, .{
///         .name = "MyColor",
///         .description = "A color enum with a custom alias.",
///     });
///     red, green, blue
/// };
/// ```
pub inline fn Alias(comptime T: type, comptime methods: anytype, comptime opts: Options.AliasOptions(T)) type {
    comptime {
        if (@typeInfo(T) != .@"enum")
            @compileError(@typeName(T) ++ " must be an enum to use Alias strategy");
    }
    comptime Internals.Assertions.assertMethodsIsStruct(methods);
    comptime Internals.Assertions.assertValidMethods(methods);
    return comptime Internals.ShapeData.Shape(T, void, .alias, null, null, methods, opts, null);
}

/// Declare `T` as a typed alias (tagged union).
///
/// Tagged unions are represented as Lua tables with a single
/// variant-name key. Use this for discriminated union types where
/// each variant carries typed payload data.
///
/// Example:
/// ```zig
/// const Event = union(enum) {
///     click: struct { x: i32, y: i32 },
///     keypress: struct { key: u8 },
///     pub const ZUA_SHAPE = zua.Shape.TypedAlias(Event, .{}, .{
///         .name = "Event",
///         .variant_descriptions = .{
///             .click = .{
///                 .description = "Mouse click event.",
///                 .field_descriptions = .{
///                     .x = "Horizontal position.",
///                     .y = "Vertical position.",
///                 },
///             },
///             .keypress = .{
///                 .description = "Keyboard press event.",
///             },
///         },
///     });
/// };
/// ```
pub inline fn TypedAlias(comptime T: type, comptime methods: anytype, comptime opts: Options.TypedAliasOptions(T)) type {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"union" or info.@"union".tag_type == null)
            @compileError(@typeName(T) ++ " must be a tagged union to use TypedAlias strategy");
    }
    comptime Internals.Assertions.assertMethodsIsStruct(methods);
    comptime Internals.Assertions.assertValidMethods(methods);
    return comptime Internals.ShapeData.Shape(T, void, .typed_alias, null, null, methods, opts, null);
}

/// Wraps a Zig function so it can be called from Lua.
///
/// `Shape.Fn(fn, options)` returns a type. The type IS the value. Assign
/// it directly to a struct field or pass it to `addBinding` without
/// creating an instance.
///
/// The wrapper auto-detects `*Context` as the first parameter and injects
/// the current call context. Parameters after context (or the first param
/// if context is absent) are decoded from Lua arguments in order. VarArgs
/// as the last parameter captures remaining Lua values. The return value
/// is pushed back to Lua: single values directly, tuples as multiple
/// returns, `void` as no return.
///
/// Example:
/// ```zig
/// const module = .{
///     .add = zua.Shape.Fn(add, .{ .description = "Adds two integers." }),
///     .greet = zua.Shape.Fn(greet, .{ .description = "Greets a user." }),
/// };
/// try state.addGlobals(&ctx, module);
/// ```
pub fn Fn(comptime function: anytype, comptime opts: Options.Fn) type {
    const FunctionType = @TypeOf(function);
    if (comptime @typeInfo(FunctionType) != .@"fn") {
        @compileError("Fn expects a function, got " ++ @typeName(FunctionType));
    }
    const fn_info = comptime @typeInfo(FunctionType).@"fn";
    const has_context = comptime fn_info.params.len > 0 and
        fn_info.params[0].type != null and
        fn_info.params[0].type.? == *Context;
    return Internals.Trampoline.ShapeFn(function, has_context, opts);
}

test {
    std.testing.refAllDecls(@This());
}
