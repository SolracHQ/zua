//! Zig-friendly isocline wrapper over the isocline C API.
//!
//! This module keeps the original isocline semantics, but exposes Zig slice
//! types, boolean results, and documented aliases so the API feels natural
//! from Zig.

const std = @import("std");
const isocline_c = @import("isocline");

/// Isocline version.
pub const Version = isocline_c.IC_VERSION;

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

/// Read input from the user using rich editing abilities.
///
/// The returned slice is borrowed from the NUL-terminated C string returned by
/// isocline and is only valid until the returned value is freed using
/// `freeMemory`.
/// Returns `null` on error, or if the user typed ctrl+d or ctrl+c.
pub fn readline(prompt: ?[]const u8) ?[:0]const u8 {
    const result = isocline_c.ic_readline(if (prompt) |p| p.ptr else null);
    return if (result) |p| std.mem.span(p) else null;
}

/// Read input with a custom completer and highlighter.
///
/// Both callbacks can be `null` in which case the defaults are used.
/// The returned slice is borrowed from the NUL-terminated C string and is only
/// valid until it is freed with `freeMemory`.
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

/// Print formatted with bbcode markup.
pub const printf = isocline_c.ic_printf;

/// Print formatted with bbcode markup.
pub const vprintf = isocline_c.ic_vprintf;

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

/// Set the default completion handler.
///
/// There can only be one default completion function. Setting it again
/// disables the previous one. The initial completer is `ic_complete_filename`.
pub fn setDefaultCompleter(completer: ?*const CompleterFn, arg: ?*anyopaque) void {
    isocline_c.ic_set_default_completer(completer, arg);
}

/// Add a completion candidate from a completion callback.
///
/// The completion string is copied by isocline and does not need to be
/// preserved or allocated by the caller.
/// Returns `true` to continue trying to find more completions. Returns
/// `false` when the callback should stop adding completions.
pub fn addCompletion(cenv: ?*CompletionEnv, completion: [:0]const u8) bool {
    return isocline_c.ic_add_completion(cenv, completion.ptr);
}

/// Add a completion candidate with display and help text.
///
/// The `display` is used to show the completion in the menu, and `help` is
/// displayed for hints. Both can be `null` for the default.
/// Returns `true` to continue trying to find more completions. Returns
/// `false` when the callback should stop.
pub fn addCompletionEx(cenv: ?*CompletionEnv, completion: [:0]const u8, display: ?[:0]const u8, help: ?[:0]const u8) bool {
    return isocline_c.ic_add_completion_ex(
        cenv,
        completion.ptr,
        if (display) |d| d.ptr else null,
        if (help) |h| h.ptr else null,
    );
}

/// Add many completions from a null-terminated array of C strings.
///
/// The `completions` array must be terminated with `null`. All elements are
/// added if they start with `prefix`.
/// Returns `true` to continue trying to add completions. Returns `false` when
/// the callback should stop.
pub fn addCompletions(cenv: ?*CompletionEnv, prefix: [:0]const u8, completions: [*][*]const u8) bool {
    return isocline_c.ic_add_completions(cenv, prefix.ptr, completions);
}

/// Complete a filename using optional roots and extensions.
///
/// If `roots` is `null`, the current directory is used. If `extensions` is
/// `null`, any extension will match. If a directory is completed, the
/// `dir_separator` is appended when it is not `0`.
pub fn completeFilename(cenv: ?*CompletionEnv, prefix: [:0]const u8, dir_separator: u8, roots: ?[:0]const u8, extensions: ?[:0]const u8) void {
    isocline_c.ic_complete_filename(
        cenv,
        prefix.ptr,
        dir_separator,
        if (roots) |r| r.ptr else null,
        if (extensions) |e| e.ptr else null,
    );
}

/// Set a prompt marker and the continuation prompt marker.
///
/// Pass `null` for `prompt_marker` to use the default "> ".
/// Pass `null` for `continuation_prompt_marker` to have it match `prompt_marker`.
pub fn setPromptMarker(prompt_marker: ?[:0]const u8, continuation_prompt_marker: ?[:0]const u8) void {
    isocline_c.ic_set_prompt_marker(
        if (prompt_marker) |p| p.ptr else null,
        if (continuation_prompt_marker) |c| c.ptr else null,
    );
}

/// Get the current prompt marker.
pub fn getPromptMarker() ?[:0]const u8 {
    const result = isocline_c.ic_get_prompt_marker();
    return if (result) |p| std.mem.span(p) else null;
}

/// Get the current continuation prompt marker.
pub fn getContinuationPromptMarker() ?[:0]const u8 {
    const result = isocline_c.ic_get_continuation_prompt_marker();
    return if (result) |p| std.mem.span(p) else null;
}

/// Disable or enable multi-line input (enabled by default).
/// Returns the previous setting.
pub fn enableMultiline(enable: bool) bool {
    return isocline_c.ic_enable_multiline(enable);
}

/// Disable or enable sound (enabled by default).
/// A beep is used when tab cannot find any completion for example.
/// Returns the previous setting.
pub fn enableBeep(enable: bool) bool {
    return isocline_c.ic_enable_beep(enable);
}

/// Disable or enable color output (enabled by default).
/// Returns the previous setting.
pub fn enableColor(enable: bool) bool {
    return isocline_c.ic_enable_color(enable);
}

/// Disable or enable duplicate entries in the history (disabled by default).
/// Returns the previous setting.
pub fn enableHistoryDuplicates(enable: bool) bool {
    return isocline_c.ic_enable_history_duplicates(enable);
}

/// Disable or enable automatic tab completion after a completion
/// to expand as far as possible if the completions are unique.
/// Returns the previous setting.
pub fn enableAutoTab(enable: bool) bool {
    return isocline_c.ic_enable_auto_tab(enable);
}

/// Disable or enable preview of a completion selection (enabled by default).
/// Returns the previous setting.
pub fn enableCompletionPreview(enable: bool) bool {
    return isocline_c.ic_enable_completion_preview(enable);
}

/// Disable or enable automatic indentation of continuation lines in multiline
/// input so it aligns with the initial prompt.
/// Returns the previous setting.
pub fn enableMultilineIndent(enable: bool) bool {
    return isocline_c.ic_enable_multiline_indent(enable);
}

/// Disable or enable display of short help messages for history search etc.
/// Full help is always displayed when pressing F1 regardless of this setting.
/// Returns the previous setting.
pub fn enableInlineHelp(enable: bool) bool {
    return isocline_c.ic_enable_inline_help(enable);
}

/// Disable or enable hinting (enabled by default).
/// Shows a hint inline when there is a single possible completion.
/// Returns the previous setting.
pub fn enableHint(enable: bool) bool {
    return isocline_c.ic_enable_hint(enable);
}

/// Set millisecond delay before a hint is displayed.
///
/// Can be zero. (500ms by default).
pub fn setHintDelay(delay_ms: c_long) c_long {
    return isocline_c.ic_set_hint_delay(delay_ms);
}

/// Disable or enable syntax highlighting (enabled by default).
/// This applies regardless whether a syntax highlighter callback was set.
/// Returns the previous setting.
pub fn enableHighlight(enable: bool) bool {
    return isocline_c.ic_enable_highlight(enable);
}

/// Set millisecond delay for reading escape sequences in order to distinguish
/// a lone ESC from the start of an escape sequence.
/// The defaults are 100ms and 10ms.
pub fn setTtyEscDelay(initial_delay_ms: c_long, followup_delay_ms: c_long) void {
    isocline_c.ic_set_tty_esc_delay(initial_delay_ms, followup_delay_ms);
}

/// Enable or disable brace matching.
pub fn enableBraceMatching(enable: bool) bool {
    return isocline_c.ic_enable_brace_matching(enable);
}

/// Set the default syntax highlighter callback.
///
/// There can only be one highlight function. Setting a new one disables the
/// previous one.
pub fn setDefaultHighlighter(highlighter: ?*const HighlighterFn, arg: ?*anyopaque) void {
    isocline_c.ic_set_default_highlighter(highlighter, arg);
}

/// Highlight an input line using an already-formatted output string.
pub fn highlightFormatted(henv: ?*HighlightEnv, input: [*c]const u8, formatted: [*c]const u8) void {
    isocline_c.ic_highlight_formatted(henv, input, formatted);
}

/// Set the matching brace pairs.
///
/// Pass `null` for the default `"()[]{}"`.
pub fn setMatchingBraces(brace_pairs: ?[]const u8) void {
    isocline_c.ic_set_matching_braces(if (brace_pairs) |b| b.ptr else null);
}

/// Enable or disable automatic brace insertion (enabled by default).
/// Returns the previous setting.
pub fn enableBraceInsertion(enable: bool) bool {
    return isocline_c.ic_enable_brace_insertion(enable);
}

/// Set the brace pairs used for automatic insertion.
///
/// Pass `null` for the default `()[]{}""''`.
pub fn setInsertionBraces(brace_pairs: ?[]const u8) void {
    isocline_c.ic_set_insertion_braces(if (brace_pairs) |b| b.ptr else null);
}

/// Complete a word (token) using the given completer.
///
/// Calls `fun` on the current word and adjusts completion results to replace
/// that part of the input.
/// If `is_word_char` is `null`, the default `ic_char_is_nonseparator` is used.
pub fn completeWord(cenv: ?*CompletionEnv, prefix: [:0]const u8, fun: ?*const CompleterFn, is_word_char: ?*const CharClassFn) void {
    isocline_c.ic_complete_word(cenv, prefix.ptr, fun, is_word_char);
}

/// Complete a quoted word using the given completer.
///
/// Takes quotes and escape characters into account when completing. If
/// `is_word_char` is `null`, the default `ic_char_is_nonseparator` is used.
pub fn completeQword(cenv: ?*CompletionEnv, prefix: [:0]const u8, fun: ?*const CompleterFn, is_word_char: ?*const CharClassFn) void {
    isocline_c.ic_complete_qword(cenv, prefix.ptr, fun, is_word_char);
}

/// Complete a quoted word with custom word characters, escape character, and quote handling.
pub fn completeQwordEx(cenv: ?*CompletionEnv, prefix: [:0]const u8, fun: ?*const CompleterFn, is_word_char: ?*const CharClassFn, escape_char: u8, quote_chars: ?[]const u8) void {
    isocline_c.ic_complete_qword_ex(
        cenv,
        prefix.ptr,
        fun,
        is_word_char,
        escape_char,
        if (quote_chars) |q| q.ptr else null,
    );
}

/// Get the raw completion input string and optional cursor location.
pub fn completionInput(cenv: ?*CompletionEnv, cursor: ?*c_long) ?[]const u8 {
    const result = isocline_c.ic_completion_input(cenv, cursor);
    return if (result) |p| std.mem.span(p) else null;
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
///
/// Cannot be used with most completion transformers such as `completeWord`.
/// `delete_before` and `delete_after` specify the number of bytes to remove
/// before and after the cursor before inserting `completion`.
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
pub fn startsWith(s: [:0]const u8, prefix: [:0]const u8) bool {
    return isocline_c.ic_starts_with(s.ptr, prefix.ptr);
}

/// Check whether `s` begins with `prefix` ignoring ASCII case.
pub fn istartsWith(s: [:0]const u8, prefix: [:0]const u8) bool {
    return isocline_c.ic_istarts_with(s.ptr, prefix.ptr);
}

/// Test whether the text is whitespace.
pub fn charIsWhite(s: [:0]const u8, len: c_long) bool {
    return isocline_c.ic_char_is_white(s.ptr, len);
}

/// Test whether the text is not whitespace.
pub fn charIsNonwhite(s: [:0]const u8, len: c_long) bool {
    return isocline_c.ic_char_is_nonwhite(s.ptr, len);
}

/// Test whether the text is a separator.
pub fn charIsSeparator(s: [:0]const u8, len: c_long) bool {
    return isocline_c.ic_char_is_separator(s.ptr, len);
}

/// Test whether the text is not a separator.
pub fn charIsNonseparator(s: [:0]const u8, len: c_long) bool {
    return isocline_c.ic_char_is_nonseparator(s.ptr, len);
}

/// Test whether the text is a letter.
pub fn charIsLetter(s: [:0]const u8, len: c_long) bool {
    return isocline_c.ic_char_is_letter(s.ptr, len);
}

/// Test whether the text is a digit.
pub fn charIsDigit(s: [:0]const u8, len: c_long) bool {
    return isocline_c.ic_char_is_digit(s.ptr, len);
}

/// Test whether the text is a hexadecimal digit.
pub fn charIsHexDigit(s: [:0]const u8, len: c_long) bool {
    return isocline_c.ic_char_is_hexdigit(s.ptr, len);
}

/// Test whether the text is an identifier letter.
pub fn charIsIdLetter(s: [:0]const u8, len: c_long) bool {
    return isocline_c.ic_char_is_idletter(s.ptr, len);
}

/// Test whether the text is a filename letter.
pub fn charIsFilenameLetter(s: [:0]const u8, len: c_long) bool {
    return isocline_c.ic_char_is_filename_letter(s.ptr, len);
}

/// If this is a token start, return the length. Otherwise return 0.
pub fn isToken(s: [:0]const u8, pos: c_long, is_token_char: ?*const CharClassFn) c_long {
    return isocline_c.ic_is_token(s.ptr, pos, is_token_char);
}

/// Does this match the specified token?
pub fn matchToken(s: [:0]const u8, pos: c_long, is_token_char: ?*const CharClassFn, token: [:0]const u8) c_long {
    return isocline_c.ic_match_token(s.ptr, pos, is_token_char, token.ptr);
}

/// Do any of the specified tokens match?
pub fn matchAnyToken(s: [:0]const u8, pos: c_long, is_token_char: ?*const CharClassFn, tokens: [*][*]const u8) c_long {
    return isocline_c.ic_match_any_token(s.ptr, pos, is_token_char, tokens);
}

/// Initialize for terminal output.
///
/// Call this before using the terminal write functions.
pub fn termInit() void {
    isocline_c.ic_term_init();
}

/// Call this when done with the terminal functions.
pub fn termDone() void {
    isocline_c.ic_term_done();
}

/// Flush the terminal output.
pub fn termFlush() void {
    isocline_c.ic_term_flush();
}

/// Write a string to the console and process CSI escape sequences.
pub fn termWrite(s: [:0]const u8) void {
    isocline_c.ic_term_write(s.ptr);
}

/// Write a string to the console and end with a newline.
pub fn termWriteln(s: [:0]const u8) void {
    isocline_c.ic_term_writeln(s.ptr);
}

/// Write formatted to the console and process CSI escape sequences.
pub const termWritef = isocline_c.ic_term_writef;

/// Write a formatted string to the console.
pub const termVWritef = isocline_c.ic_term_vwritef;

/// Set text attributes from a style.
pub fn termStyle(style: [:0]const u8) void {
    isocline_c.ic_term_style(style.ptr);
}

/// Set text attribute to bold.
pub fn termBold(enable: bool) void {
    isocline_c.ic_term_bold(enable);
}

/// Set text attribute to underline.
pub fn termUnderline(enable: bool) void {
    isocline_c.ic_term_underline(enable);
}

/// Set text attribute to italic.
pub fn termItalic(enable: bool) void {
    isocline_c.ic_term_italic(enable);
}

/// Set text attribute to reverse video.
pub fn termReverse(enable: bool) void {
    isocline_c.ic_term_reverse(enable);
}

/// Set ansi palette color.
pub fn termColorAnsi(foreground: bool, color: c_int) void {
    isocline_c.ic_term_color_ansi(foreground, color);
}

/// Set 24-bit RGB color.
pub fn termColorRgb(foreground: bool, color: u32) void {
    isocline_c.ic_term_color_rgb(foreground, color);
}

/// Reset the text attributes.
pub fn termReset() void {
    isocline_c.ic_term_reset();
}

/// Get the palette used by the terminal.
pub fn termGetColorBits() c_int {
    return isocline_c.ic_term_get_color_bits();
}

/// Thread-safe way to asynchronously unblock a readline.
///
/// Behaves as if the user pressed ctrl-C and causes `readline` to return `null`.
pub fn asyncStop() bool {
    return isocline_c.ic_async_stop();
}

test "isocline wrapper compiles" {
    _ = CompletionEnv;
    _ = HighlightEnv;
    _ = CompleterFn;
    _ = HighlighterFn;
    _ = completeFilename;
}
