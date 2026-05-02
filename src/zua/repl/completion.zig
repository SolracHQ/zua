//! Completion helper wrappers for the Zua REPL.
//!
//! This module exposes a small completion API for REPL clients while hiding
//! the raw `isocline` callback state and C interop details.

const std = @import("std");
const lua = @import("../../lua/lua.zig");
const State = @import("../state/state.zig").State;
const Context = @import("../state/context.zig").Context;
const Table = @import("../handlers/table.zig").Table;
const Meta = @import("../meta.zig");
const Mapper = @import("../mapper/mapper.zig");
const Native = @import("../functions/native.zig");
const Object = @import("../typed/object.zig").Object;
const isocline = @import("../../isocline/isocline.zig");
const Config = @import("config.zig");

/// REPL completion helper.
///
/// This wrapper hides `isocline` internals and provides a safe interface for
/// completion callbacks. One `Completer` is created as a zua object per REPL
/// session and reused across tab events by updating `_env` and `_ctx`.
pub const Completer = struct {
    pub const ZUA_META = Meta.Object(Completer, .{
    .add = Native.new(add, .{}).withDescriptions(&.{
        .{ .name = "candidate", .description = "Completion candidate string." },
    }).withDescription("Add a completion candidate."),
    .addEx = Native.new(addEx, .{}).withDescriptions(&.{
        .{ .name = "candidate", .description = "Completion candidate string." },
        .{ .name = "display", .description = "Optional alternate display text." },
        .{ .name = "help", .description = "Optional help text shown alongside the candidate." },
    }).withDescription("Add a completion candidate with display and help text."),
    }).withDescription("Session-scoped completion helper wrapping isocline internals.")
        .withName("Completer");

    _env: ?*isocline.CompletionEnv,
    _ctx: *Context,

    /// Returns the per-cycle arena allocator for temporary completions.
    pub fn arena(self: *Completer) std.mem.Allocator {
        return self._ctx.arena();
    }

    /// Returns the shared `State` backing this completion session.
    pub fn state(self: *Completer) *State {
        return self._ctx.state;
    }

    /// Publishes `candidate` as a completion result.
    ///
    /// Returns `true` to continue adding more candidates, or `false` when the
    /// callback should stop.
    pub fn add(self: *Completer, candidate: [:0]const u8) bool {
        return isocline.addCompletion(self._env, candidate);
    }

    /// Publishes a completion candidate with alternate display text and help.
    ///
    /// `display` is shown in the completion menu when the candidate is focused.
    /// `help` appears as a hint alongside the candidate. Both can be `null`.
    /// Returns `true` to continue adding more candidates, or `false` when the
    /// callback should stop.
    pub fn addEx(self: *Completer, candidate: [:0]const u8, display: ?[:0]const u8, help: ?[:0]const u8) bool {
        return isocline.addCompletionEx(self._env, candidate, display, help);
    }
};

/// Completion callback type used by the REPL.
///
/// The callback is invoked on each tab-completion request.
/// `prefix` is the current token or expression fragment to complete.
///
/// The callback may call `completer.add(candidate)` or
/// `completer.addEx(candidate, display, help)` to publish results.
pub const CompletionHook = ?*const fn (
    completer: *Completer,
    prefix: []const u8,
) void;

/// Internal completion state forwarded through the isocline opaque callback arg.
///
/// This state carries the shared config, the per-cycle Context, and a
/// session-scoped `Completer` handle allocated as a zua Object.
pub const CompletionState = struct {
    config: *Config,
    ctx: *Context,
    completer: Object(Completer),
};

/// Public isocline completion callback wrapper used by Zua.
///
/// When registered as the default completer, this wrapper bridges raw line
/// editor events into Zua's CompletionState. A stack guard protects the Lua
/// stack across the callback boundary.
pub fn completionCallbackC(cenv: ?*isocline.CompletionEnv, prefix: [*c]const u8) callconv(.c) void {
    const cs: *CompletionState = @ptrCast(@alignCast(isocline.completionArg(cenv) orelse return));
    const previous_top = lua.getTop(cs.ctx.state.luaState);
    defer lua.setTop(cs.ctx.state.luaState, previous_top);

    cs.completer.get()._ctx = cs.ctx;

    const raw_prefix = std.mem.span(prefix);
    isocline.completeWord(cenv, raw_prefix, completionWord, if (cs.config.runtime_completion) &luaCompletionWordChar else null);
}

/// Completion entry point for isocline.
///
/// Runs runtime Lua completion, the Zig completion hook, and the Lua
/// completion hook in order. All three contribute candidates.
fn completionWord(cenv: ?*isocline.CompletionEnv, prefix: [*c]const u8) callconv(.c) void {
    const cs: *CompletionState = @ptrCast(@alignCast(isocline.completionArg(cenv) orelse return));
    const raw_input = std.mem.span(prefix);

    const completer_ptr = cs.completer.get();
    completer_ptr._env = cenv;

    // 1. Runtime Lua completion
    if (cs.config.runtime_completion and raw_input.len > 0) {
        const chain_prefix = extractChainPrefix(raw_input);
        if (chain_prefix.len > 0) {
            if (findLastSeparator(chain_prefix)) |sep_index| {
                const separator = chain_prefix[sep_index];
                const filter_prefix = chain_prefix[sep_index + 1 ..];
                const object_prefix = chain_prefix[0..sep_index];
                const full_prefix = chain_prefix[0 .. sep_index + 1];
                if (separator == ':') {
                    completeMemberPrefix(cs.ctx, completer_ptr, object_prefix, full_prefix, filter_prefix, true);
                } else {
                    completeMemberPrefix(cs.ctx, completer_ptr, object_prefix, full_prefix, filter_prefix, false);
                }
            } else {
                completeGlobalPrefix(cs.ctx, completer_ptr, chain_prefix);
            }
        }
    }

    // 2. Zig-side completion hook
    if (cs.config.completion_hook) |hook| {
        hook(completer_ptr, raw_input);
    }

    // 3. Lua-side completion hook
    if (cs.config.lua_completion_hook) |hook| {
        hook.call(cs.ctx, .{ cs.completer, raw_input }) catch {};
    }
}

/// Extracts the current completion fragment from a full input prefix.
///
/// For runtime Lua completion, this returns the suffix after the last
/// non-identifier separator so callers can complete the current token.
fn extractChainPrefix(prefix: []const u8) []const u8 {
    var i = prefix.len;
    while (i > 0) : (i -= 1) {
        const c = prefix[i - 1];
        const is_id = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.' or c == ':';
        if (!is_id) break;
    }
    return prefix[i..];
}

/// Finds the last field or method separator in the completion prefix.
///
/// Returns the separator index for `.` or `:`, or `null` if none exists.
fn findLastSeparator(prefix: []const u8) ?usize {
    var i: usize = prefix.len;
    while (i > 0) : (i -= 1) {
        const c = prefix[i - 1];
        if (c == '.' or c == ':') return i - 1;
    }
    return null;
}

/// Validates characters for the runtime Lua completion word parser.
///
/// Accepts letters, digits, underscores, dots, and colons.
fn luaCompletionWordChar(s: [*c]const u8, len: c_long) callconv(.c) bool {
    const len_u: usize = @intCast(len);
    var i: usize = 0;
    while (i < len_u) : (i += 1) {
        const c = s[i];
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '.' or c == ':') continue;
        return false;
    }
    return true;
}

/// Resolves a chained object prefix against the live Lua runtime.
///
/// Example inputs are `foo.bar` and `foo:method`. The resolved value is left
/// on the Lua stack for the caller to inspect.
fn resolveObjectPrefix(
    ctx: *Context,
    object_prefix: []const u8,
) bool {
    const state = ctx.state;
    const previous_top = lua.getTop(state.luaState);
    _ = state.globals();

    var start: usize = 0;
    while (start < object_prefix.len) {
        var end = start;
        while (end < object_prefix.len) {
            const c = object_prefix[end];
            if (c == '.' or c == ':') break;
            end += 1;
        }
        const segment = object_prefix[start..end];
        if (segment.len == 0) {
            lua.setTop(state.luaState, previous_top);
            return false;
        }

        const current_index = lua.absIndex(state.luaState, -1);
        const current_table = Table.fromBorrowed(state, current_index);
        const segment_name_unterminated = std.fmt.allocPrintSentinel(ctx.arena(), "{s}", .{segment}, 0) catch return false;
        const segment_name: [:0]const u8 = segment_name_unterminated;
        const prim = current_table.get(ctx, segment_name, Mapper.Primitive) catch return false;
        if (prim == .nil) {
            lua.setTop(state.luaState, previous_top);
            return false;
        }

        lua.remove(state.luaState, current_index);
        start = if (end < object_prefix.len) end + 1 else end;
    }

    return true;
}

/// Appends a candidate to the completer using the provided prefix.
fn addCompletionCandidate(
    completer: *Completer,
    prefix: []const u8,
    key: []const u8,
) void {
    const candidate = std.fmt.allocPrintSentinel(completer.arena(), "{s}{s}", .{ prefix, key }, 0) catch return;
    _ = completer.add(candidate);
}

/// Adds matching keys from a Lua table to the completion results.
///
/// If `restrict_functions` is true, only function-valued keys are returned.
fn collectTableKeys(
    ctx: *Context,
    completer: *Completer,
    table_index: lua.StackIndex,
    filter_prefix: []const u8,
    prefix: []const u8,
    restrict_functions: bool,
) void {
    const state = ctx.state;
    const previous_top = lua.getTop(state.luaState);
    defer lua.setTop(state.luaState, previous_top);

    const table = Table.fromBorrowed(state, table_index);
    const keys = table.keys(ctx) catch return;

    for (keys) |key| {
        if (!std.mem.startsWith(u8, key, filter_prefix)) continue;

        if (restrict_functions) {
            const val_type = lua.getField(state.luaState, table_index, key);
            if (val_type == .function) {
                addCompletionCandidate(completer, prefix, key);
            }
            lua.pop(state.luaState, 1);
        } else {
            addCompletionCandidate(completer, prefix, key);
        }
    }
}

/// Adds string values from a Lua table as completion candidates.
fn collectStringValues(
    state: *lua.State,
    completer: *Completer,
    table_index: lua.StackIndex,
    filter_prefix: []const u8,
    prefix: []const u8,
) void {
    const previous_top = lua.getTop(state);
    defer lua.setTop(state, previous_top);

    lua.pushNil(state);
    while (lua.next(state, table_index)) {
        if (lua.valueType(state, -1) == .string) {
            if (lua.toString(state, -1)) |value| {
                if (std.mem.startsWith(u8, value, filter_prefix)) {
                    addCompletionCandidate(completer, prefix, value);
                }
            }
        }
        lua.pop(state, 1);
    }
}

/// Completes fields from a runtime introspection function.
fn collectIntrospection(
    ctx: *Context,
    completer: *Completer,
    introspection_fn_index: lua.StackIndex,
    filter_prefix: []const u8,
    prefix: []const u8,
) void {
    const state = ctx.state;
    const previous_top = lua.getTop(state.luaState);
    defer lua.setTop(state.luaState, previous_top);

    lua.pushValue(state.luaState, introspection_fn_index);
    lua.pushNil(state.luaState);
    lua.pushString(state.luaState, "__introspection");
    const rc = lua.pcall(state.luaState, 2, 1, 0);
    if (rc != 0) {
        if (lua.valueType(state.luaState, -1) == .string) {
            if (lua.toString(state.luaState, -1)) |err| _ = err;
        }
        return;
    }
    if (lua.valueType(state.luaState, -1) != .table) {
        return;
    }
    const introspection_index = lua.absIndex(state.luaState, -1);
    collectTableKeys(ctx, completer, introspection_index, filter_prefix, prefix, false);
    collectStringValues(state.luaState, completer, introspection_index, filter_prefix, prefix);
}

/// Collects completion candidates from the current Lua value.
///
/// This handles direct table keys and metatable-based introspection.
fn collectFromValue(
    ctx: *Context,
    completer: *Completer,
    filter_prefix: []const u8,
    prefix: []const u8,
    restrict_functions: bool,
) void {
    const state = ctx.state;
    const previous_top = lua.getTop(state.luaState);
    defer lua.setTop(state.luaState, previous_top);

    const value_index = lua.absIndex(state.luaState, -1);
    const value_type = lua.valueType(state.luaState, value_index);
    if (value_type == .table) {
        collectTableKeys(ctx, completer, value_index, filter_prefix, prefix, restrict_functions);
    }

    if (lua.getMetatable(state.luaState, value_index)) {
        const mt_index = lua.absIndex(state.luaState, -1);
        if (lua.getField(state.luaState, mt_index, "__index") == .table) {
            collectTableKeys(ctx, completer, lua.absIndex(state.luaState, -1), filter_prefix, prefix, restrict_functions);
        } else if (lua.valueType(state.luaState, -1) == .function) {
            collectIntrospection(ctx, completer, lua.absIndex(state.luaState, -1), filter_prefix, prefix);
        }
    }
}

/// Completes top-level Lua globals using the current runtime environment.
fn completeGlobalPrefix(
    ctx: *Context,
    completer: *Completer,
    filter_prefix: []const u8,
) void {
    const state = ctx.state;
    const previous_top = lua.getTop(state.luaState);
    defer lua.setTop(state.luaState, previous_top);

    _ = state.globals();
    collectTableKeys(ctx, completer, lua.absIndex(state.luaState, -1), filter_prefix, "", false);
}

/// Completes members for a chained expression like `foo.` or `foo:`.
fn completeMemberPrefix(
    ctx: *Context,
    completer: *Completer,
    object_prefix: []const u8,
    full_prefix: []const u8,
    filter_prefix: []const u8,
    restrict_functions: bool,
) void {
    const state = ctx.state;
    const previous_top = lua.getTop(state.luaState);
    defer lua.setTop(state.luaState, previous_top);

    if (!resolveObjectPrefix(ctx, object_prefix)) return;
    collectFromValue(ctx, completer, filter_prefix, full_prefix, restrict_functions);
}

test {
    std.testing.refAllDecls(@This());
}
