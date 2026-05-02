const std = @import("std");
const zua = @import("zua");

pub fn main(init: std.process.Init) !void {
    // Initialize the Zua state, which manages the Lua environment and resources.
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    // Each REPL line executes with a fresh Context for scratch allocation.
    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    var conf: zua.Object(zua.Repl.Config) = .create(state, .{ .lua_completion = true, .history_path = "zua_repl_history.txt" });
    defer conf.release();

    try state.addGlobals(&ctx, .{ .repl = conf });

    try zua.Repl.run(state, conf.get());
}
