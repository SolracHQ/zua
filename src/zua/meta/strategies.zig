const std = @import("std");
const meta = @import("./meta.zig");
const metadata = @import("metadata.zig");
const helpers = @import("helpers.zig");

/// Declare `T` as an `.object` translation strategy.
///
/// Object strategy types are represented as full userdata in Lua and
/// expose methods through a metatable. Use this for Zig values that need
/// identity, mutability, and controlled behavior from Lua.
///
/// Example:
/// ```zig
/// const Process = struct {
///     pub const ZUA_META = zua.Meta.Object(Process, .{
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
    comptime helpers.assertContainerType(T);
    return comptime metadata.MetaData(T, void, .object, null, null, methods, options);
}

/// Declare `T` as a `.table` translation strategy.
///
/// Table strategy types are represented as Lua tables with fields mapped from
/// Zig struct members or union variants. This is the default strategy.
///
/// Example:
/// ```zig
/// const Point = struct {
///     pub const ZUA_META = zua.Meta.Table(Point, .{}, .{
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
    comptime helpers.assertContainerType(T);
    comptime helpers.assertTaggedIfUnion(T);
    return comptime metadata.MetaData(T, void, .table, null, null, methods, options);
}

/// Declare `T` as a `.ptr` translation strategy.
///
/// Pointer strategy types are represented as Lua light userdata, with no
/// metatable or field access. Use this for opaque handles that Lua should
/// not inspect or mutate.
pub inline fn Ptr(comptime T: type, comptime options: meta.MetaOptions(T, .ptr)) type {
    comptime helpers.assertContainerType(T);
    return comptime metadata.MetaData(T, void, .ptr, null, null, null, options);
}

/// Declare `T` as a `.capture` translation strategy.
///
/// Capture strategy types are stored as userdata in upvalue 1 of a Lua
/// C closure created by `Native.closure`. The struct is allocated once when
/// the closure is pushed and a `*T` pointer is injected into every call through
/// the capture parameter.
///
/// Methods are supported and follow the same rules as `.object`. Use `__gc` to
/// release any owned resources when Lua collects the closure. Encode and decode
/// hooks are not allowed on capture strategy types.
///
/// Arguments:
/// - T: The struct type to use as the closure's captured state.
/// - methods: A comptime struct of method name–function pairs.
/// - options: Optional documentation metadata.
///
/// Returns:
/// - `type`: The metadata type to assign to `pub const ZUA_META`.
///
/// Example:
/// ```zig
/// const CounterState = struct {
///     pub const ZUA_META = zua.Meta.Capture(@This(), .{
///         .__gc = cleanup,
///     }, .{});
///     count: i32,
///     step: i32,
///
///     fn cleanup(self: *CounterState) void {
///         _ = self; // release owned resources here
///     }
/// };
/// ```
pub inline fn Capture(comptime T: type, comptime methods: anytype, comptime options: meta.MetaOptions(T, .capture)) type {
    comptime helpers.assertContainerType(T);
    return comptime metadata.MetaData(T, void, .capture, null, null, methods, options);
}

/// Declare `T` as a string-backed enum with automatic string conversion.
///
/// This sets up `T` as a `.table` type and derives encode/decode hooks so the
/// enum is pushed as a string and parsed from string values.
pub inline fn strEnum(comptime T: type, comptime methods: anytype, comptime options: meta.MetaOptions(T, .table)) type {
    if (comptime @typeInfo(T) != .@"enum")
        @compileError("strEnum requires an enum type, got " ++ @typeName(T));
    return comptime metadata.MetaData(T, []const u8, .table, helpers.strEnumEncode(T), helpers.strEnumDecode(T), methods, options);
}

/// Declare `T` as a list-type `.object` translation strategy.
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
///     pub const ZUA_META = zua.Meta.List(ProcList, getElements, .{
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
    comptime helpers.assertContainerType(T);
    comptime helpers.assertNoListCollisions(methods);
    return comptime metadata.MetaData(T, void, .object, null, null, helpers.mergeMethodSets(helpers.generateListMethodsSet(T, getElements), methods), options);
}

test {
    std.testing.refAllDecls(@This());
}
