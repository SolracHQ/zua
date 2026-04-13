//! Thin wrapper over the vendored linenoise C API.
//!
//! This module keeps the raw C surface available through `c`, re-exports the
//! main callback and state types, and adds a few small Zig helpers for the
//! ownership and sentinel-based parts of the API.
const std = @import("std");

pub const c = @import("c");

/// Mutable editor state used by the multiplexed linenoise API.
///
/// The caller owns the storage and passes it to `startEdit`, `feedEdit`,
/// `hide`, `show`, and `stopEdit`.
pub const State = c.struct_linenoiseState;

/// Completion list populated by tab-completion callbacks.
pub const Completions = c.linenoiseCompletions;

/// Callback invoked when linenoise needs tab-completion candidates.
pub const CompletionCallback = c.linenoiseCompletionCallback;

/// Callback invoked to show inline hints on the right of the prompt.
pub const HintsCallback = c.linenoiseHintsCallback;

/// Callback invoked to rewrite the current buffer with syntax highlighting.
pub const HighlightCallback = c.linenoiseHighlightCallback;

/// Callback used to free buffers returned by a hints callback.
pub const FreeHintsCallback = c.linenoiseFreeHintsCallback;

pub const EditStartError = error{
    EmptyBuffer,
    Failed,
};

pub const FeedError = error{
    Canceled,
    EndOfFile,
    Failed,
};

pub const HistoryError = error{
    Failed,
};

pub const FeedResult = union(enum) {
    more,
    line: [:0]u8,
};

/// Registers the callback used for tab-completion.
pub fn setCompletionCallback(callback: CompletionCallback) void {
    c.linenoiseSetCompletionCallback(callback);
}

/// Registers the callback used to show hints on the right side of the prompt.
pub fn setHintsCallback(callback: HintsCallback) void {
    c.linenoiseSetHintsCallback(callback);
}
/// Registers the callback used to apply syntax highlighting to the edited buffer.
pub fn setHighlightCallback(callback: HighlightCallback) void {
    c.linenoiseSetHighlightCallback(callback);
}
/// Registers the function that frees buffers returned by a hints callback.
pub fn setFreeHintsCallback(callback: FreeHintsCallback) void {
    c.linenoiseSetFreeHintsCallback(callback);
}

/// Adds a completion option from inside a completion callback.
pub fn addCompletion(completions: *Completions, completion: [:0]const u8) void {
    c.linenoiseAddCompletion(completions, completion.ptr);
}

/// Hides the current edited line while using the multiplexed API.
pub fn hide(state: *State) void {
    c.linenoiseHide(state);
}

/// Re-renders the current edited line while using the multiplexed API.
pub fn show(state: *State) void {
    c.linenoiseShow(state);
}

/// Clears the terminal screen.
pub fn clearScreen() void {
    c.linenoiseClearScreen();
}

/// Enables or disables multi-line editing mode.
pub fn setMultiLine(enabled: bool) void {
    c.linenoiseSetMultiLine(@intFromBool(enabled));
}

/// Prints key codes for interactive debugging.
pub fn printKeyCodes() void {
    c.linenoisePrintKeyCodes();
}

/// Replaces visible input with `*`, useful for password prompts.
pub fn maskModeEnable() void {
    c.linenoiseMaskModeEnable();
}

/// Disables password masking mode.
pub fn maskModeDisable() void {
    c.linenoiseMaskModeDisable();
}

/// Reads a single line using linenoise's blocking API.
///
/// The returned buffer is owned by linenoise and must be released with
/// `freeLine`.
pub fn readLine(prompt: [:0]const u8) ?[:0]u8 {
    const ptr = c.linenoise(prompt.ptr) orelse return null;
    return toOwnedLine(ptr);
}

/// Frees a line buffer previously returned by `readLine` or `feedEdit`.
pub fn freeLine(line: [:0]u8) void {
    c.linenoiseFree(line.ptr);
}

/// Starts linenoise's multiplexed editing API using a caller-owned buffer.
pub fn startEdit(state: *State, stdin_fd: c_int, stdout_fd: c_int, buffer: []u8, prompt: [:0]const u8) EditStartError!void {
    if (buffer.len == 0) return EditStartError.EmptyBuffer;
    if (c.linenoiseEditStart(state, stdin_fd, stdout_fd, buffer.ptr, buffer.len, prompt.ptr) != 0) {
        return EditStartError.Failed;
    }
}

/// Advances a multiplexed edit session.
///
/// While the user is still editing, this returns `.more`. Once the line is
/// complete it returns an owned buffer that must be released with `freeLine`.
pub fn feedEdit(state: *State) FeedError!FeedResult {
    const ptr = c.linenoiseEditFeed(state) orelse {
        return switch (currentErrno()) {
            c.EAGAIN => FeedError.Canceled,
            c.ENOENT => FeedError.EndOfFile,
            else => FeedError.Failed,
        };
    };

    if (ptr == c.linenoiseEditMore) return .more;
    return .{ .line = toOwnedLine(ptr) };
}

/// Restores the terminal after a multiplexed edit session.
pub fn stopEdit(state: *State) void {
    c.linenoiseEditStop(state);
}

/// Adds a line to the in-memory history.
///
/// Returns `false` when the line was not added, which includes duplicate lines
/// and allocation failures in the underlying C implementation.
pub fn historyAdd(line: [:0]const u8) bool {
    return c.linenoiseHistoryAdd(line.ptr) == 1;
}

/// Updates the maximum in-memory history length.
pub fn historySetMaxLen(len: c_int) bool {
    return c.linenoiseHistorySetMaxLen(len) == 1;
}

/// Saves the current history to disk.
pub fn historySave(path: [:0]const u8) HistoryError!void {
    if (c.linenoiseHistorySave(path.ptr) != 0) return HistoryError.Failed;
}

/// Loads history entries from disk.
///
/// The C API returns `-1` both when the file is missing and when loading
/// fails for another reason, so the wrapper keeps that behavior as a single
/// `error.Failed` result.
pub fn historyLoad(path: [:0]const u8) HistoryError!void {
    if (c.linenoiseHistoryLoad(path.ptr) != 0) return HistoryError.Failed;
}

fn toOwnedLine(ptr: [*c]u8) [:0]u8 {
    const sentinel_ptr: [*:0]u8 = @ptrCast(ptr);
    return std.mem.span(sentinel_ptr);
}

fn currentErrno() c_int {
    return c.__errno_location().*;
}
