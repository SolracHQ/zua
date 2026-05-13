const std = @import("std");
const zua = @import("zua");

const RangeIter = struct {
    pub const ZUA_SHAPE = zua.Shape.Closure(@This(), next, null, .{});
    start: usize,
    end: usize,
    step: usize,

    fn next(state: *RangeIter, unknown: ?void, prev: ?usize) ?usize {
        _ = unknown;
        _ = prev;
        if (state.start >= state.end) {
            return null;
        }
        const current = state.start;
        state.start += state.step;
        return current;
    }
};

fn range(start: usize, end: usize, step: usize) RangeIter {
    return .{
        .start = start,
        .end = end,
        .step = step,
    };
}

pub fn main(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    try state.addGlobals(&ctx, .{ .range = range });

    var exe = zua.Executor{};
    exe.execute(&ctx, .{ .stack_trace = .arena, .code = .{ .string =
        \\for i in range(0, 10, 2) do
        \\    print(i)
        \\end
    } }) catch |err| {
        std.debug.print("Execution failed with err {s}: {s}\n", .{ @errorName(err), exe.stack_trace orelse exe.err orelse "unknown error" });
    };
}
