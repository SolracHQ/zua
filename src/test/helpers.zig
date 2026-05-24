const std = @import("std");
const zua = @import("../root.zig");
const State = zua.State;
const Context = zua.Context;

pub const TestContext = struct {
    state: *State,
    ctx: Context,

    pub fn deinit(self: *@This()) void {
        self.ctx.deinit();
        self.state.deinit();
    }
};

pub fn setup() !TestContext {
    const state = try State.init(std.testing.allocator, std.testing.io);
    errdefer state.deinit();
    const ctx = Context.init(state);
    return TestContext{ .state = state, .ctx = ctx };
}
