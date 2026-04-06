const std = @import("std");
const zua = @import("zua");

const Result = zua.Result;

const Process = struct {
    const Self = @This();

    pub const ZUA_META = zua.meta.Object(Self, .{
        .getPid = getPid,
        .getName = getName,
    });

    pid: i32,
    name: []const u8,

    fn getPid(self: *Self) Result(i32) {
        return Result(i32).ok(self.pid);
    }

    fn getName(self: *Self) Result([]const u8) {
        return Result([]const u8).ok(self.name);
    }
};

const demo_processes = [_]Process{
    .{ .pid = 101, .name = "alpha" },
    .{ .pid = 202, .name = "beta" },
};

fn listProcesses(z: *zua.Zua) Result([]const Process) {
    const processes = z.allocator.dupe(Process, demo_processes[0..demo_processes.len]) catch {
        return Result([]const Process).errStatic("out of memory");
    };
    return Result([]const Process).owned(processes);
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa, init.io);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("list_processes", zua.ZuaFn.from(listProcesses, .{
        .parse_error = "list_processes expects no arguments",
    }));

    try z.exec(
        \\local processes = list_processes()
        \\assert(#processes == 2)
        \\assert(processes[1]:getPid() == 101)
        \\assert(processes[1]:getName() == "alpha")
        \\assert(processes[2]:getPid() == 202)
        \\assert(processes[2]:getName() == "beta")
        \\print("object slice example ok")
    );
}
