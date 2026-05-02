const std = @import("std");
const zua = @import("zua");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);

    const cmd = if (args.len > 1) args[1] else "";

    if (std.mem.eql(u8, cmd, "repl")) {
        return runRepl(init);
    }

    if (std.mem.eql(u8, cmd, "docs")) {
        return generateDocs(init);
    }

    if (std.mem.eql(u8, cmd, "run") and args.len > 2) {
        return runFile(init, args[2]);
    }

    if (std.mem.eql(u8, cmd, "eval") and args.len > 2) {
        const expr = try std.mem.join(init.gpa, " ", args[2..]);
        defer init.gpa.free(expr);
        return evalExpr(init, expr);
    }

    // help (or unknown command, or no args)
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stderr(), init.io, buf[0..]);
    try writer.interface.writeAll(
        \\zua is a Zig toolkit for Lua 5.4 interop.
        \\
        \\This binary is a demo of what the library can do, similar to Lua's own
        \\interpreter. The real power of zua is using it as a dependency to build
        \\Zig code that interacts with Lua seamlessly.
        \\
        \\Usage: zua [command] [args]
        \\
        \\Commands:
        \\  repl         Start the interactive Zua REPL.
        \\               Play with the `repl` global to see how the runtime
        \\               Lua-facing controls work in real time.
        \\
        \\  docs         Print Lua editor stubs for the REPL config types,
        \\               completers, token kinds, and style types.
        \\
        \\  run <file>   Execute a Lua source file.
        \\
        \\  eval <expr>  Evaluate a Lua expression and print returned values.
        \\
        \\  help         Show this message.
        \\
    );
    try writer.interface.flush();
}

fn runRepl(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    var conf: zua.Object(zua.Repl.Config) = .create(state, .{ .history_path = "zua_repl_history.txt" });
    defer conf.release();

    try state.addGlobals(&ctx, .{ .repl = conf });

    try zua.Repl.run(state, conf.get());
}

fn runFile(init: std.process.Init, path: []const u8) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    var executor: zua.Executor = .{};
    executor.execute(&ctx, .{ .code = .{ .file = path } }) catch {
        const msg = ctx.err orelse "unknown error";
        try printMessage(state, "Error: ", msg);
        return;
    };
}

fn evalExpr(init: std.process.Init, source: []const u8) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    const previous_top = zua.lua.getTop(state.luaState);
    defer zua.lua.setTop(state.luaState, previous_top);

    var executor: zua.Executor = .{};
    executor.eval_untyped(&ctx, .{ .code = .{ .string = source } }) catch {
        const msg = ctx.err orelse "unknown error";
        try printMessage(state, "Error: ", msg);
        return;
    };
    try printResults(state, previous_top);
}

fn generateDocs(init: std.process.Init) !void {
    const stubs = try zua.Docs.generateModule(init.gpa, .{
        zua.Repl.Config,
        zua.Repl.Completer,
        zua.Repl.highlight.TokenKind,
        zua.Repl.highlight.Color,
        zua.Repl.highlight.Style,
    }, "zua");
    defer init.gpa.free(stubs);
    std.debug.print("{s}", .{stubs});
}

fn printResults(state: *zua.State, previous_top: zua.lua.StackIndex) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer[0..]);
    const top = zua.lua.getTop(state.luaState);
    if (top == previous_top) return;

    var first = true;
    var index: zua.lua.StackIndex = previous_top + 1;
    while (index <= top) : (index += 1) {
        if (!first) try writer.interface.print(", ", .{});
        first = false;

        const abs = zua.lua.absIndex(state.luaState, index);
        if (zua.lua.toDisplayString(state.luaState, abs)) |v| {
            try writer.interface.print("{s}", .{v});
        } else {
            try writer.interface.print("{s}", .{zua.lua.typeName(state.luaState, zua.lua.valueType(state.luaState, abs))});
        }
    }
    try writer.interface.print("\n", .{});
    try writer.interface.flush();
}

fn printMessage(state: *zua.State, prefix: []const u8, message: []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer[0..]);
    try writer.interface.print("{s}{s}\n", .{ prefix, message });
    try writer.interface.flush();
}
