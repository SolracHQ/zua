//! Zig-friendly isocline wrapper over the isocline C API.
//!
//! This module keeps the original isocline semantics, but exposes Zig slice
//! types, boolean results, and documented aliases so the API feels natural
//! from Zig.

const std = @import("std");
const isocline_c = @import("isocline");

/// Completion environment passed into completion callbacks.
pub const CompletionEnv = isocline_c.ic_completion_env_t;

/// Syntax highlighting environment passed into highlighter callbacks.
pub const HighlightEnv = isocline_c.ic_highlight_env_t;

/// Custom allocation callback used by isocline.
pub const AllocFn = isocline_c.ic_malloc_fun_t;

/// Custom reallocation callback used by isocline.
pub const ReallocFn = isocline_c.ic_realloc_fun_t;

/// Custom free callback used by isocline.
pub const FreeFn = isocline_c.ic_free_fun_t;

/// Completion callback called by isocline when the user requests completion.
pub const CompleterFn = fn (cenv: ?*CompletionEnv, prefix: [*c]const u8) callconv(.c) void;

/// Syntax highlighting callback called by isocline while editing input.
pub const HighlighterFn = fn (henv: ?*HighlightEnv, input: [*c]const u8, arg: ?*anyopaque) callconv(.c) void;

/// Character-class callback used by completion and quoting helpers.
pub const CharClassFn = fn (s: [*c]const u8, len: c_long) callconv(.c) bool;

/// Initialize isocline with default allocation and standard error output.
pub fn init(useStdErr: bool) void {
    isocline_c.ic_init(useStdErr);
}

/// Initialize isocline with a custom allocator.
pub fn initCustomAlloc(malloc: ?*const AllocFn, realloc: ?*const ReallocFn, free: ?*const FreeFn) void {
    isocline_c.ic_init_custom_alloc(malloc, realloc, free);
}

/// Initialize isocline with a custom allocator and optional stderr handling.
pub fn initCustomAllocEx(malloc: ?*const AllocFn, realloc: ?*const ReallocFn, free: ?*const FreeFn, useStdErr: bool) void {
    isocline_c.ic_init_custom_alloc_ex(malloc, realloc, free, useStdErr);
}

/// Free memory allocated by isocline.
pub fn freeMemory(ptr: ?*anyopaque) void {
    isocline_c.ic_free(ptr);
}

/// Duplicate a string using isocline's allocator.
///
/// The returned slice is borrowed from the NUL-terminated C string returned by
/// isocline and is only valid until the returned value is freed using
/// `freeMemory`.
pub fn strdup(s: []const u8) ?[]const u8 {
    const result = isocline_c.ic_strdup(s.ptr);
    return if (result) |p| std.mem.span(p) else null;
}

/// Read a line of input from the user.
///
/// The returned slice is borrowed from the NUL-terminated C string returned by
/// isocline and is only valid until the returned value is freed using
/// `freeMemory`.
pub fn readline(prompt: ?[]const u8) ?[]const u8 {
    const result = isocline_c.ic_readline(if (prompt) |p| p.ptr else null);
    return if (result) |p| std.mem.span(p) else null;
}

/// Read a line of input with a custom completer and highlighter.
///
/// The returned slice is borrowed from the NUL-terminated C string returned by
/// isocline and is only valid until the returned value is freed using
/// `freeMemory`.
pub fn readlineEx(prompt: ?[]const u8, completer: ?*const CompleterFn, completer_arg: ?*anyopaque, highlighter: ?*const HighlighterFn, highlighter_arg: ?*anyopaque) ?[]const u8 {
    const result = isocline_c.ic_readline_ex(
        if (prompt) |p| p.ptr else null,
        completer,
        completer_arg,
        highlighter,
        highlighter_arg,
    );
    return if (result) |p| std.mem.span(p) else null;
}

/// Print a string with bbcode markup.
pub fn print(s: []const u8) void {
    isocline_c.ic_print(s.ptr);
}

/// Print a string with bbcode markup and a trailing newline.
pub fn println(s: []const u8) void {
    isocline_c.ic_println(s.ptr);
}

/// Define or redefine a style for bbcode output.
pub fn styleDef(style_name: []const u8, fmt: []const u8) void {
    isocline_c.ic_style_def(style_name.ptr, fmt.ptr);
}

/// Start a global bbcode style.
pub fn styleOpen(fmt: []const u8) void {
    isocline_c.ic_style_open(fmt.ptr);
}

/// Close the most recently opened bbcode style.
pub fn styleClose() void {
    isocline_c.ic_style_close();
}

/// Enable or disable history persistence.
pub fn setHistory(filename: [:0]const u8, max_entries: c_long) void {
    isocline_c.ic_set_history(filename.ptr, max_entries);
}

/// Remove the last entry added to the history.
pub fn historyRemoveLast() void {
    isocline_c.ic_history_remove_last();
}

/// Clear the in-memory history.
pub fn historyClear() void {
    isocline_c.ic_history_clear();
}

/// Append a new entry to the history.
pub fn historyAdd(entry: [:0]const u8) void {
    isocline_c.ic_history_add(entry.ptr);
}

/// Set the default completion callback.
pub fn setDefaultCompleter(completer: ?*const CompleterFn, arg: ?*anyopaque) void {
    isocline_c.ic_set_default_completer(completer, arg);
}

/// Add a completion candidate from a completion callback.
pub fn addCompletion(cenv: ?*CompletionEnv, completion: [:0]const u8) bool {
    return isocline_c.ic_add_completion(cenv, completion.ptr);
}

/// Add a completion candidate with display and help text.
pub fn addCompletionEx(cenv: ?*CompletionEnv, completion: [:0]const u8, display: ?[:0]const u8, help: ?[:0]const u8) bool {
    return isocline_c.ic_add_completion_ex(
        cenv,
        completion.ptr,
        if (display) |d| d.ptr else null,
        if (help) |h| h.ptr else null,
    );
}

/// Add many completions from a null-terminated array of C strings.
pub fn addCompletions(cenv: ?*CompletionEnv, prefix: [:0]const u8, completions: [*][*]const u8) bool {
    return isocline_c.ic_add_completions(cenv, prefix.ptr, completions);
}

/// Complete a filename using optional roots and extensions.
pub fn completeFilename(cenv: ?*CompletionEnv, prefix: [:0]const u8, dir_separator: u8, roots: ?[:0]const u8, extensions: ?[:0]const u8) void {
    isocline_c.ic_complete_filename(
        cenv,
        prefix.ptr,
        dir_separator,
        if (roots) |r| r.ptr else null,
        if (extensions) |e| e.ptr else null,
    );
}

/// Enable or disable multiline input.
pub fn enableMultiline(enable: bool) bool {
    return isocline_c.ic_enable_multiline(enable);
}

/// Enable or disable beep output.
pub fn enableBeep(enable: bool) bool {
    return isocline_c.ic_enable_beep(enable);
}

/// Enable or disable color output.
pub fn enableColor(enable: bool) bool {
    return isocline_c.ic_enable_color(enable);
}

/// Enable or disable duplicate history entries.
pub fn enableHistoryDuplicates(enable: bool) bool {
    return isocline_c.ic_enable_history_duplicates(enable);
}

/// Enable or disable automatic tab completion.
pub fn enableAutoTab(enable: bool) bool {
    return isocline_c.ic_enable_auto_tab(enable);
}

/// Enable or disable completion preview.
pub fn enableCompletionPreview(enable: bool) bool {
    return isocline_c.ic_enable_completion_preview(enable);
}

/// Enable or disable multiline indentation.
pub fn enableMultilineIndent(enable: bool) bool {
    return isocline_c.ic_enable_multiline_indent(enable);
}

/// Enable or disable inline help.
pub fn enableInlineHelp(enable: bool) bool {
    return isocline_c.ic_enable_inline_help(enable);
}

/// Enable or disable hinting.
pub fn enableHint(enable: bool) bool {
    return isocline_c.ic_enable_hint(enable);
}

/// Set the delay before a hint is displayed.
pub fn setHintDelay(delay_ms: c_long) c_long {
    return isocline_c.ic_set_hint_delay(delay_ms);
}

/// Enable or disable syntax highlighting.
pub fn enableHighlight(enable: bool) bool {
    return isocline_c.ic_enable_highlight(enable);
}

/// Set the escape-sequence read delay for TTY input.
pub fn setTtyEscDelay(initial_delay_ms: c_long, followup_delay_ms: c_long) void {
    isocline_c.ic_set_tty_esc_delay(initial_delay_ms, followup_delay_ms);
}

/// Enable or disable brace matching.
pub fn enableBraceMatching(enable: bool) bool {
    return isocline_c.ic_enable_brace_matching(enable);
}

/// Set the default syntax highlighter callback.
pub fn setDefaultHighlighter(highlighter: ?*const HighlighterFn, arg: ?*anyopaque) void {
    isocline_c.ic_set_default_highlighter(highlighter, arg);
}

/// Highlight an input line using an already-formatted output string.
pub fn highlightFormatted(henv: ?*HighlightEnv, input: [*c]const u8, formatted: [*c]const u8) void {
    isocline_c.ic_highlight_formatted(henv, input, formatted);
}

/// Set the matching brace pairs.
pub fn setMatchingBraces(brace_pairs: ?[]const u8) void {
    isocline_c.ic_set_matching_braces(if (brace_pairs) |b| b.ptr else null);
}

/// Enable or disable automatic brace insertion.
pub fn enableBraceInsertion(enable: bool) bool {
    return isocline_c.ic_enable_brace_insertion(enable);
}

/// Set the brace pairs used for automatic insertion.
pub fn setInsertionBraces(brace_pairs: ?[]const u8) void {
    isocline_c.ic_set_insertion_braces(if (brace_pairs) |b| b.ptr else null);
}

/// Get the raw completion input string and optional cursor location.
pub fn completionInput(cenv: ?*CompletionEnv, cursor: ?*c_long) ?*const u8 {
    return isocline_c.ic_completion_input(cenv, cursor);
}

/// Get the argument passed to a completion callback.
pub fn completionArg(cenv: ?*const CompletionEnv) ?*anyopaque {
    return isocline_c.ic_completion_arg(cenv);
}

/// Return whether any completions have been recorded.
pub fn hasCompletions(cenv: ?*const CompletionEnv) bool {
    return isocline_c.ic_has_completions(cenv);
}

/// Request completion early-stop behavior.
pub fn stopCompleting(cenv: ?*const CompletionEnv) bool {
    return isocline_c.ic_stop_completing(cenv);
}

/// Add a primitive completion candidate with fine-grained edit control.
pub fn addCompletionPrim(cenv: ?*CompletionEnv, completion: []const u8, display: ?[]const u8, help: ?[]const u8, delete_before: c_long, delete_after: c_long) bool {
    return isocline_c.ic_add_completion_prim(
        cenv,
        completion.ptr,
        if (display) |d| d.ptr else null,
        if (help) |h| h.ptr else null,
        delete_before,
        delete_after,
    );
}

/// Return the previous UTF-8 code point position in `s`.
pub fn prevChar(s: []const u8, pos: c_long) c_long {
    return isocline_c.ic_prev_char(s.ptr, pos);
}

/// Return the next UTF-8 code point position in `s`.
pub fn nextChar(s: []const u8, pos: c_long) c_long {
    return isocline_c.ic_next_char(s.ptr, pos);
}

/// Check whether `s` begins with `prefix`.
pub fn startsWith(s: []const u8, prefix: []const u8) bool {
    return isocline_c.ic_starts_with(s.ptr, prefix.ptr);
}

/// Check whether `s` begins with `prefix` ignoring ASCII case.
pub fn istartsWith(s: []const u8, prefix: []const u8) bool {
    return isocline_c.ic_istarts_with(s.ptr, prefix.ptr);
}

/// Test whether the text is whitespace.
pub fn charIsWhite(s: []const u8, len: c_long) bool {
    return isocline_c.ic_char_is_white(s.ptr, len);
}

/// Test whether the text is not whitespace.
pub fn charIsNonwhite(s: []const u8, len: c_long) bool {
    return isocline_c.ic_char_is_nonwhite(s.ptr, len);
}

/// Test whether the text is a separator.
pub fn charIsSeparator(s: []const u8, len: c_long) bool {
    return isocline_c.ic_char_is_separator(s.ptr, len);
}

/// Test whether the text is not a separator.
pub fn charIsNonseparator(s: []const u8, len: c_long) bool {
    return isocline_c.ic_char_is_nonseparator(s.ptr, len);
}

/// Test whether the text is a letter.
pub fn charIsLetter(s: []const u8, len: c_long) bool {
    return isocline_c.ic_char_is_letter(s.ptr, len);
}

/// Test whether the text is a hexadecimal digit.
pub fn charIsHexDigit(s: []const u8, len: c_long) bool {
    return isocline_c.ic_char_is_hexdigit(s.ptr, len);
}

/// Test whether the text is an identifier letter.
pub fn charIsIdLetter(s: []const u8, len: c_long) bool {
    return isocline_c.ic_char_is_idletter(s.ptr, len);
}

/// Test whether the text is a filename letter.
pub fn charIsFilenameLetter(s: []const u8, len: c_long) bool {
    return isocline_c.ic_char_is_filename_letter(s.ptr, len);
}

test "isocline wrapper compiles" {
    _ = CompletionEnv;
    _ = HighlightEnv;
    _ = CompleterFn;
    _ = HighlighterFn;
    _ = completeFilename;
}
