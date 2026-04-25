//! Completion helper wrappers for the Zua REPL.
//!
//! This module exposes a small completion API for REPL clients while hiding
//! the raw `isocline` callback state and C interop details.
const std = @import("std");

pub const isocline = @import("../../isocline/isocline.zig");

/// REPL completion helper.
///
/// This wrapper hides `isocline` internals and provides a safe interface for
/// completion callbacks.
pub const Completer = struct {
    _env: ?*isocline.CompletionEnv,
    _arena: std.heap.ArenaAllocator,

    pub fn arena(self: *Completer) std.mem.Allocator {
        return self._arena.allocator();
    }

    pub fn add(self: *Completer, candidate: [:0]const u8) bool {
        return isocline.addCompletion(self._env, candidate);
    }

    pub fn addEx(self: *Completer, candidate: [:0]const u8, display: ?[:0]const u8, help: ?[:0]const u8) bool {
        return isocline.addCompletionEx(self._env, candidate, display, help);
    }
};

/// Completion callback type used by the REPL.
///
/// The callback is invoked with the current input prefix and a helper object
/// that can add completion candidates from a host environment.
pub const CompletionHook = ?*const fn (
    completer: *Completer,
    prefix: []const u8,
    arg: ?*anyopaque,
) void;

/// Internal state forwarded through the `isocline` opaque callback arg.
pub const CompletionState = struct {
    hook: CompletionHook,
    arg: ?*anyopaque,
    allocator: std.mem.Allocator,
};

/// C-calling-convention callback registered with isocline.
///
/// This bridges the raw `isocline` completer invocation into the safe
/// `CompletionHook` callback type used by REPL clients.
pub fn completionCallbackC(cenv: ?*isocline.CompletionEnv, prefix: [*c]const u8) callconv(.c) void {
    const raw_arg = isocline.completionArg(cenv) orelse return;
    const state: *CompletionState = @ptrCast(@alignCast(raw_arg));
    const hook = state.hook orelse return;
    var completer = Completer{
        ._env = cenv,
        ._arena = std.heap.ArenaAllocator.init(state.allocator),
    };
    defer completer._arena.deinit();
    hook(&completer, std.mem.span(prefix), state.arg);
}

test {
    std.testing.refAllDecls(@This());
}
