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
        \\  docs         Print Lua editor stubs for the REPL global.
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

    var conf: zua.Handlers.Typed.Object(zua.Repl.Config) = .create(state, .{ .history_path = "zua_repl_history.txt" });
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

    var executor: zua.Executor = .{};
    const results = executor.eval(&ctx, zua.Mapper.VarArgs, .{ .code = .{ .string = source } }) catch {
        const msg = ctx.err orelse "unknown error";
        try printMessage(state, "Error: ", msg);
        return;
    };
    try printValues(state, results.args);
}

fn printValues(state: *zua.State, values: []const zua.Mapper.Primitive) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer[0..]);

    var first = true;
    for (values) |prim| {
        if (!first) try writer.interface.print(", ", .{});
        first = false;

        switch (prim) {
            .nil => try writer.interface.print("nil", .{}),
            .boolean => |b| {
                const s = if (b) "true" else "false";
                try writer.interface.print("{s}", .{s});
            },
            .integer => |i| try writer.interface.print("{d}", .{i}),
            .float => |f| try writer.interface.print("{e}", .{f}),
            .string => |s| try writer.interface.print("\"{s}\"", .{s}),
            .table => try writer.interface.print("table", .{}),
            .function => try writer.interface.print("function", .{}),
            .light_userdata => try writer.interface.print("userdata:light", .{}),
            .userdata => try writer.interface.print("userdata", .{}),
            .handle => try writer.interface.print("handle", .{}),
        }
    }
    try writer.interface.print("\n", .{});
    try writer.interface.flush();
}

fn generateDocs(init: std.process.Init) !void {
    var generator = zua.Docs.init(init.gpa);
    defer generator.deinit();
    try generator.addBinding("repl", zua.Repl.Config{});
    const stubs = try generator.generate();
    std.debug.print("{s}", .{stubs});
}

fn printMessage(state: *zua.State, prefix: []const u8, message: []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), state.io, stdout_buffer[0..]);
    try writer.interface.print("{s}{s}\n", .{ prefix, message });
    try writer.interface.flush();
}
