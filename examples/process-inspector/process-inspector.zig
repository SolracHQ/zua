const std = @import("std");
const zua = @import("zua");

const Inspector = @import("lib/inspector.zig").Inspector;
const Store = @import("lib/data.zig").Store;

// State.init creates a fresh Lua VM. The other path is State.libState which
// attaches to an existing lua_State from a host calling require().
// Context provides a call-local arena (ctx.arena()) and persistent
// allocator (ctx.heap()) attached to the State.

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const store = try Store.init(gpa);

    const state = try zua.State.init(gpa, init.io);
    defer state.deinit();

    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    // Registry stores values across callbacks. registry() pushes a
    // reference onto the Lua stack that must be released when done.
    // Here we store a one-time reference so scan callbacks can
    // retrieve it. Globals and registry share the same Lua state,
    // so be intentional about what goes where.
    try Store.register(&ctx, store);

    // addGlobals reads ZUA_SHAPE on each value at comptime and pushes
    // it into Lua's global table. After this, Lua code references
    // `inspector` as a global.
    try state.addGlobals(&ctx, .{ .inspector = Inspector{} });

    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    if (args.len >= 2) {
        var executor = zua.Executor{};
        executor.execute(&ctx, .{ .code = .{ .file = args[1] } }) catch {
            if (ctx.err) |msg| std.debug.print("{s}\n", .{msg});
        };
        return;
    }

    var config = zua.Repl.Config{
        .welcome_message =
        \\process-inspector: REPL-based memory inspection demo.
        \\Examples:
        \\  procs = inspector.scan()
        \\  p = procs[1]
        \\  r = p:regions("rw-p")
        \\  e = r[1]:scan("i32", {gt = 100})
        \\  e[1]:set(9999)
        \\
        ,
        .prompt = "inspector",
        .runtime_completion = true,
        .stack_trace = true,
        .history_path = "/tmp/.process_inspector_history",
    };
    zua.Repl.run(state, &config) catch |err| {
        std.debug.print("repl error: {s}\n", .{@errorName(err)});
    };
}
