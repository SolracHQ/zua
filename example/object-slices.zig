const std = @import("std");
const zua = @import("zua");

const Process = struct {
    const Self = @This();

    pub const ZUA_META = zua.Meta.Object(Self, .{
        .getPid = getPid,
        .getName = getName,
    });

    pid: i32,
    name: []const u8,

    fn getPid(self: *Self) i32 {
        return self.pid;
    }

    fn getName(self: *Self) []const u8 {
        return self.name;
    }
};

const demo_processes = [_]Process{
    .{ .pid = 101, .name = "alpha" },
    .{ .pid = 202, .name = "beta" },
};

fn listProcesses(ctx: *zua.Context) ![]const Process {
    return ctx.allocator().dupe(Process, demo_processes[0..demo_processes.len]) catch try ctx.failTyped([]const Process, "out of memory");
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.State.init(init.gpa, init.io);
    defer z.deinit();
    var executor = zua.Executor{};
    var ctx = zua.Context.init(z);
    defer ctx.deinit();

    const globals = z.globals();
    defer globals.release();

    globals.set(&ctx, "list_processes", zua.ZuaFn.new(listProcesses, .{
        .parse_err_fmt = "list_processes expects no arguments: {s}",
    }));

    try executor.execute(&ctx, .{ .code = .{ .string =
        \\local processes = list_processes()
        \\assert(#processes == 2)
        \\assert(processes[1]:getPid() == 101)
        \\assert(processes[1]:getName() == "alpha")
        \\assert(processes[2]:getPid() == 202)
        \\assert(processes[2]:getName() == "beta")
        \\print("object slice example ok")
    } });
}
