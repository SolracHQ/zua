//! Zig-friendly Lua 5.4 wrapper over the system C headers.
//!
//! This module stays close to Lua's C API, but smooths over the parts that are
//! awkward from Zig: integer-as-boolean results become `bool`, a few common C
//! types get semantic aliases, constants follow Zig's constant naming style, and
//! the public surface is documented for LSP hover.
const std = @import("std");

pub const lua_c = @import("lua");

/// Opaque Lua thread handle used by all API calls.
pub const State = lua_c.lua_State;

/// Stack position accepted by Lua C API functions.
pub const StackIndex = c_int;

/// Count of stack slots, arguments, or results.
pub const StackCount = c_int;

/// Lua floating-point type.
pub const Number = lua_c.lua_Number;

/// Lua signed integer type.
pub const Integer = lua_c.lua_Integer;

/// Lua unsigned integer type.
pub const Unsigned = lua_c.lua_Unsigned;

/// Context value threaded through yieldable continuation APIs.
pub const KContext = lua_c.lua_KContext;

/// Native function callable from Lua.
pub const CFunction = lua_c.lua_CFunction;

/// Continuation function used by `lua_callk` and `lua_pcallk`.
pub const KFunction = lua_c.lua_KFunction;

/// Chunk reader callback used by `lua_load`.
pub const Reader = lua_c.lua_Reader;

/// Chunk writer callback used by `lua_dump`.
pub const Writer = lua_c.lua_Writer;

/// Allocator callback used when creating custom Lua states.
pub const Alloc = lua_c.lua_Alloc;

/// Warning callback installed with `lua_setwarnf`.
pub const WarnFunction = lua_c.lua_WarnFunction;

/// Debug record used by Lua's debug API.
pub const Debug = lua_c.lua_Debug;

/// Function registration record used by `luaL_setfuncs`.
pub const Reg = lua_c.luaL_Reg;

/// Incremental string builder used by the Lua auxiliary library.
pub const Buffer = lua_c.luaL_Buffer;

/// Errors surfaced by the Zig helpers in this module.
pub const Error = error{
    OutOfMemory,
    Runtime,
    Syntax,
    MessageHandler,
    File,
    Unknown,
};

/// A null-terminated script path suitable for Lua's file-loading API.
pub const Script = struct {
    path: [:0]const u8,
};

/// Lua call and execution status codes.
pub const Status = enum(c_int) {
    ok = lua_c.LUA_OK,
    yield = lua_c.LUA_YIELD,
    err_run = lua_c.LUA_ERRRUN,
    err_syntax = lua_c.LUA_ERRSYNTAX,
    err_mem = lua_c.LUA_ERRMEM,
    err_err = lua_c.LUA_ERRERR,
};

/// Converts raw Lua status codes returned by the C API into a Zig error.
pub fn statusToError(status: c_int) ?Error {
    return switch (status) {
        lua_c.LUA_OK => null,
        lua_c.LUA_ERRRUN => Error.Runtime,
        lua_c.LUA_ERRSYNTAX => Error.Syntax,
        lua_c.LUA_ERRMEM => Error.OutOfMemory,
        lua_c.LUA_ERRERR => Error.MessageHandler,
        lua_c.LUA_ERRFILE => Error.File,
        else => Error.Unknown,
    };
}

/// Value kinds returned by `valueType` and related Lua API calls.
pub const Type = enum(c_int) {
    none = lua_c.LUA_TNONE,
    nil = lua_c.LUA_TNIL,
    boolean = lua_c.LUA_TBOOLEAN,
    light_userdata = lua_c.LUA_TLIGHTUSERDATA,
    number = lua_c.LUA_TNUMBER,
    string = lua_c.LUA_TSTRING,
    table = lua_c.LUA_TTABLE,
    function = lua_c.LUA_TFUNCTION,
    userdata = lua_c.LUA_TUSERDATA,
    thread = lua_c.LUA_TTHREAD,
};

/// Comparison operators accepted by `compare`.
pub const CompareOp = enum(c_int) {
    eq = lua_c.LUA_OPEQ,
    lt = lua_c.LUA_OPLT,
    le = lua_c.LUA_OPLE,
};

/// Arithmetic and bitwise operators accepted by `arith`.
pub const ArithOp = enum(c_int) {
    add = lua_c.LUA_OPADD,
    sub = lua_c.LUA_OPSUB,
    mul = lua_c.LUA_OPMUL,
    mod = lua_c.LUA_OPMOD,
    pow = lua_c.LUA_OPPOW,
    div = lua_c.LUA_OPDIV,
    idiv = lua_c.LUA_OPIDIV,
    band = lua_c.LUA_OPBAND,
    bor = lua_c.LUA_OPBOR,
    bxor = lua_c.LUA_OPBXOR,
    shl = lua_c.LUA_OPSHL,
    shr = lua_c.LUA_OPSHR,
    unm = lua_c.LUA_OPUNM,
    bnot = lua_c.LUA_OPBNOT,
};

/// Sentinel result count meaning "return every result produced by the call".
pub const MULT_RETURN: StackCount = lua_c.LUA_MULTRET;

/// Pseudo-index of the Lua registry table.
pub const REGISTRY_INDEX: StackIndex = lua_c.LUA_REGISTRYINDEX;

/// Registry slot containing the state's main thread.
pub const RIDX_MAINTHREAD = lua_c.LUA_RIDX_MAINTHREAD;

/// Registry slot containing the global environment.
pub const RIDX_GLOBALS = lua_c.LUA_RIDX_GLOBALS;

/// Extra stack slots guaranteed when Lua calls a C function.
pub const MIN_STACK: StackCount = lua_c.LUA_MINSTACK;

/// Creates a fresh Lua state.
pub fn init() Error!*State {
    return lua_c.luaL_newstate() orelse Error.OutOfMemory;
}

/// Closes a Lua state previously created with `init`.
pub fn deinit(state: *State) void {
    lua_c.lua_close(state);
}

/// Converts an acceptable index into an absolute stack index.
pub fn absIndex(state: *State, index: StackIndex) StackIndex {
    return lua_c.lua_absindex(state, index);
}

/// Returns the current stack top.
pub fn getTop(state: *State) StackIndex {
    return lua_c.lua_gettop(state);
}

/// Sets the stack top to `index`.
pub fn setTop(state: *State, index: StackIndex) void {
    lua_c.lua_settop(state, index);
}

/// Pushes a copy of the value at `index` onto the top of the stack.
pub fn pushValue(state: *State, index: StackIndex) void {
    lua_c.lua_pushvalue(state, index);
}

/// Pushes the standard Lua traceback helper onto the stack.
pub fn pushTracebackFunction(state: *State) void {
    _ = getGlobal(state, "debug");
    _ = getField(state, -1, "traceback");
    remove(state, -2);
}

/// Ensures there is room for at least `extra_slots` more stack values.
pub fn checkStack(state: *State, extra_slots: StackCount) bool {
    return lua_c.lua_checkstack(state, extra_slots) != 0;
}

/// Returns whether the value at `index` is numeric or string-coercible to a number.
pub fn isNumber(state: *State, index: StackIndex) bool {
    return lua_c.lua_isnumber(state, index) != 0;
}

/// Returns whether the value at `index` is a string or number.
pub fn isString(state: *State, index: StackIndex) bool {
    return lua_c.lua_isstring(state, index) != 0;
}

/// Returns whether the value at `index` is represented internally as a Lua integer.
pub fn isInteger(state: *State, index: StackIndex) bool {
    return lua_c.lua_isinteger(state, index) != 0;
}

/// Converts a Lua value to Lua truthiness.
pub fn toBoolean(state: *State, index: StackIndex) bool {
    return lua_c.lua_toboolean(state, index) != 0;
}

/// Pushes `nil` onto the stack.
pub fn pushNil(state: *State) void {
    lua_c.lua_pushnil(state);
}

/// Pushes a Lua float onto the stack.
pub fn pushNumber(state: *State, value: Number) void {
    lua_c.lua_pushnumber(state, value);
}

/// Pushes a Lua integer onto the stack.
pub fn pushInteger(state: *State, value: Integer) void {
    lua_c.lua_pushinteger(state, value);
}

/// Pushes a Lua boolean onto the stack.
pub fn pushBoolean(state: *State, value: bool) void {
    lua_c.lua_pushboolean(state, @intFromBool(value));
}

/// Pushes a light userdata pointer onto the stack.
pub fn pushLightUserdata(state: *State, value: ?*const anyopaque) void {
    lua_c.lua_pushlightuserdata(state, @constCast(value));
}

/// Converts the value at `index` to a light or full userdata pointer.
pub fn toLightUserdata(state: *State, index: StackIndex) ?*anyopaque {
    return lua_c.lua_touserdata(state, index);
}

/// Converts the value at `index` to a light or full userdata pointer.
pub fn toUserdata(state: *State, index: StackIndex) ?*anyopaque {
    return lua_c.lua_touserdata(state, index);
}

/// Pushes a new userdata block onto the stack and returns the raw pointer.
pub fn newUserdata(state: *State, size: usize) *anyopaque {
    return lua_c.lua_newuserdata(state, size).?;
}

/// Pushes a Lua function pointer onto the stack.
pub fn pushFunction(state: *State, function: CFunction) void {
    pushCFunction(state, function);
}

/// Pushes the named global onto the stack and returns its Lua type.
pub fn getGlobal(state: *State, name: [:0]const u8) Type {
    return @enumFromInt(lua_c.lua_getglobal(state, name.ptr));
}

/// Pops the top value and stores it into the named global.
pub fn setGlobal(state: *State, name: [:0]const u8) void {
    lua_c.lua_setglobal(state, name.ptr);
}

/// Pushes `table[key]` onto the stack and returns the pushed value's type.
pub fn getField(state: *State, index: StackIndex, key: [:0]const u8) Type {
    return @enumFromInt(lua_c.lua_getfield(state, index, key.ptr));
}

/// Pops the top value and stores it into `table[key]`.
pub fn setField(state: *State, index: StackIndex, key: [:0]const u8) void {
    lua_c.lua_setfield(state, index, key.ptr);
}

/// Pops the top value and stores it into `table[key]` for an integer key.
pub fn setIndex(state: *State, index: StackIndex, key: Integer) void {
    lua_c.lua_seti(state, index, key);
}

/// Pushes `table[key]` for an integer key onto the stack and returns its type.
pub fn getIndex(state: *State, index: StackIndex, key: Integer) Type {
    return @enumFromInt(lua_c.lua_geti(state, index, key));
}

/// Pushes `table[key]` for an integer key onto the stack without metamethods.
pub fn rawGetI(state: *State, index: StackIndex, key: Integer) Type {
    return @enumFromInt(lua_c.lua_rawgeti(state, index, key));
}

/// Creates a table with optional array and hash capacity hints.
pub fn createTable(state: *State, array_capacity: c_int, record_capacity: c_int) void {
    lua_c.lua_createtable(state, array_capacity, record_capacity);
}

/// Returns the raw length of a string, table, or userdata.
pub fn rawLen(state: *State, index: StackIndex) Unsigned {
    return lua_c.lua_rawlen(state, index);
}

/// Compares two stack values using Lua's comparison semantics.
pub fn compare(state: *State, left: StackIndex, right: StackIndex, op: CompareOp) bool {
    return lua_c.lua_compare(state, left, right, @intFromEnum(op)) != 0;
}

/// Applies an arithmetic or bitwise operation to the top stack values.
pub fn arith(state: *State, op: ArithOp) void {
    lua_c.lua_arith(state, @intFromEnum(op));
}

/// Opens all standard Lua libraries in the given state.
pub fn openLibs(state: *State) void {
    lua_c.luaL_openlibs(state);
}

/// Creates a reference to the value on top of the stack and stores it in the table at `index`.
pub fn ref(state: *State, index: StackIndex) c_int {
    return lua_c.luaL_ref(state, index);
}

/// Releases the reference `ref` previously created with `ref`.
pub fn unref(state: *State, index: StackIndex, _ref: c_int) void {
    lua_c.luaL_unref(state, index, _ref);
}

/// Checks that argument `arg_index` is an integer and returns it.
pub fn checkInteger(state: *State, arg_index: StackIndex) Integer {
    return lua_c.luaL_checkinteger(state, arg_index);
}

/// Checks that argument `arg_index` is numeric and returns it as a Lua number.
pub fn checkNumber(state: *State, arg_index: StackIndex) Number {
    return lua_c.luaL_checknumber(state, arg_index);
}

/// Checks that argument `arg_index` is a string and returns a borrowed slice.
pub fn checkString(state: *State, arg_index: StackIndex) [:0]const u8 {
    return std.mem.span(lua_c.luaL_checkstring(state, arg_index));
}

/// Loads a script file and leaves the compiled chunk on the stack.
pub fn loadFile(state: *State, script: Script) Error!void {
    if (statusToError(lua_c.luaL_loadfilex(state, script.path.ptr, null))) |err| {
        return err;
    }
}

/// Loads a Lua chunk from a string and leaves the compiled chunk on the stack.
pub fn loadString(state: *State, source: [:0]const u8) Error!void {
    if (statusToError(lua_c.luaL_loadstring(state, source.ptr))) |err| {
        return err;
    }
}

/// Calls the function currently on the stack without protection.
pub fn call(state: *State, nargs: StackCount, nresults: StackCount) void {
    lua_c.lua_callk(state, nargs, nresults, 0, null);
}

/// Protected-call primitive returning the raw Lua status code.
pub fn pcall(state: *State, nargs: StackCount, nresults: StackCount, errfunc: StackIndex) c_int {
    return lua_c.lua_pcallk(state, nargs, nresults, errfunc, 0, null);
}

/// Calls the function on the stack and maps Lua status codes into Zig errors.
pub fn protectedCall(state: *State, nargs: StackCount, nresults: StackCount, errfunc: StackIndex) Error!void {
    if (statusToError(lua_c.lua_pcallk(state, nargs, nresults, errfunc, 0, null))) |err| {
        return err;
    }
}

/// Pops `count` values from the top of the Lua stack.
pub fn pop(state: *State, count: StackCount) void {
    lua_c.lua_settop(state, -count - 1);
}

/// Removes the value at `index`, closing the gap in the stack.
pub fn remove(state: *State, index: StackIndex) void {
    lua_c.lua_rotate(state, index, -1);
    pop(state, 1);
}

/// Inserts the top stack value at the given index.
pub fn insert(state: *State, index: StackIndex) void {
    lua_c.lua_insert(state, index);
}

/// Pushes a new empty table onto the stack.
pub fn newTable(state: *State) void {
    createTable(state, 0, 0);
}

/// Pushes a C function with no upvalues onto the stack.
pub fn pushCFunction(state: *State, function: CFunction) void {
    lua_c.lua_pushcclosure(state, function, 0);
}

/// Pushes a C closure onto the stack.
///
/// Pops `upvalue_count` values from the stack and bundles them as upvalues of
/// the new closure. Inside the trampoline, use `upvalueIndex` to get the stack
/// pseudo-index for each upvalue.
pub fn pushCClosure(state: *State, function: CFunction, upvalue_count: c_int) void {
    lua_c.lua_pushcclosure(state, function, upvalue_count);
}

/// Returns the pseudo-index for upvalue `n` of the currently running closure.
///
/// `n` is 1-based: upvalue 1 is the first value that was bundled when the
/// closure was created with `pushCClosure`.
pub fn upvalueIndex(n: c_int) StackIndex {
    return lua_c.lua_upvalueindex(n);
}

/// Pushes a byte slice as a Lua string.
pub fn pushString(state: *State, value: []const u8) void {
    _ = lua_c.lua_pushlstring(state, value.ptr, value.len);
}

/// Sets the metatable for the value at `index` using the table on top of the stack.
pub fn setMetatable(state: *State, index: StackIndex) bool {
    return lua_c.lua_setmetatable(state, index) != 0;
}

/// Assigns the stack top to upvalue `upvalue_index` of the closure at `func_index`.
pub fn setUpvalue(state: *State, func_index: StackIndex, upvalue_index: StackIndex) ?[:0]const u8 {
    const name = lua_c.lua_setupvalue(state, func_index, upvalue_index) orelse return null;
    return std.mem.span(name);
}

/// Converts the value at `index` to a Lua integer when that conversion succeeds.
pub fn toInteger(state: *State, index: StackIndex) ?Integer {
    var is_num: c_int = 0;
    const value = lua_c.lua_tointegerx(state, index, &is_num);
    if (is_num == 0) return null;
    return value;
}

/// Converts the value at `index` to a Lua number when that conversion succeeds.
pub fn toNumber(state: *State, index: StackIndex) ?Number {
    var is_num: c_int = 0;
    const value = lua_c.lua_tonumberx(state, index, &is_num);
    if (is_num == 0) return null;
    return value;
}

/// Returns a borrowed Lua string slice for the value at `index`.
///
/// The returned memory is owned by Lua and must not outlive the underlying Lua
/// value or the state that holds it on the stack.
pub fn toString(state: *State, index: StackIndex) ?[:0]const u8 {
    var len: usize = 0;
    const ptr = lua_c.lua_tolstring(state, index, &len) orelse return null;
    return ptr[0..len :0];
}

/// Coerces the value at `index` to a display string and pushes that string.
///
/// The returned slice is borrowed from Lua and remains valid while the pushed
/// string remains on the stack.
pub fn toDisplayString(state: *State, index: StackIndex) ?[]const u8 {
    var len: usize = 0;
    const ptr = lua_c.luaL_tolstring(state, index, &len) orelse return null;
    return ptr[0..len];
}

/// Raises a Lua error using the value currently on top of the stack.
pub fn raiseError(state: *State) c_int {
    return lua_c.lua_error(state);
}

/// Returns the Lua value kind at `index`.
pub fn valueType(state: *State, index: StackIndex) Type {
    return @enumFromInt(lua_c.lua_type(state, index));
}

/// Returns Lua's human-readable name for a value kind.
pub fn typeName(state: *State, lua_type: Type) [:0]const u8 {
    return std.mem.span(lua_c.lua_typename(state, @intFromEnum(lua_type)));
}
