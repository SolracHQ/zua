const std = @import("std");
const zua = @import("zua");

const IteratorState = struct {
    pub const ZUA_META = zua.Meta.Capture(@This(), .{});
    start: usize,
    end: usize,
    step: usize,
};

pub fn closure(state: *IteratorState, unknown: ?void, prev: ?usize) ?usize {
    _ = unknown;
    _ = prev;
    if (state.start >= state.end) {
        return null;
    }
    const current = state.start;
    state.start += state.step;
    return current;
}

fn range(start: usize, end: usize, step: usize) zua.ZuaFn.ZuaFnClosureType(closure, .{}) {
    return .{ .initial = .{
        .start = start,
        .end = end,
        .step = step,
    } };
}

pub fn main(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    var globals = state.globals();
    defer globals.release();

    globals.set(&ctx, "range", range);

    var exe = zua.Executor{};
    exe.execute(&ctx, .{ .stack_trace = .arena, .code = .{ .string =
        \\for i in range(0, 10, 2) do
        \\    print(i)
        \\end
    } }) catch |err| {
        std.debug.print("Execution failed with err {s}: {s}\n", .{ @errorName(err), exe.stack_trace orelse exe.err orelse "unknown error" });
    };
}
