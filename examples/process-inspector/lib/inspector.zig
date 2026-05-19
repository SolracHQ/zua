const std = @import("std");
const zua = @import("zua");

const Permissions = @import("region/perms.zig").Permissions;
const ProcessFilter = @import("process/filter.zig").Filter;
const Process = @import("process/process.zig").Process;
const ProcList = @import("process/list.zig").List;
const Entry = @import("mem/entry.zig").Entry;
const DataType = @import("mem/types.zig").DataType;
const Store = @import("data.zig").Store;
const PROCESSES = @import("data.zig").PROCESSES;

// Object strategy: opaque userdata. Lua calls methods but never sees the
// fields. With Table they would be writable keys anyone could clobber.
pub const Inspector = @This();

pub const ZUA_SHAPE = zua.Shape.Object(Inspector, .{ .__tostring = display }, .{
    .name = "Inspector",
    .description = "Fake process memory inspector.",
});

// Value couples a Shape.Fn with read-only access. zua sees the
// Shape.Fn at comptime and pushes the function. Value marks the field
// as readable but not writable from Lua, so callers get inspector.scan
// as a callable without being able to replace it.
scan: zua.Shape.Modifier.Value(struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Returns all processes, optionally filtered.",
        .args = &.{
            .{ .name = "filter", .description = "Filter with pid, name, or cmdLine." },
        },
    });
    fn impl(ctx: *zua.Context, filter: ?ProcessFilter) !ProcList {
        const proc_filter = filter orelse ProcessFilter{};
        var procs = std.ArrayList(Process).empty;
        errdefer procs.deinit(ctx.arena());
        for (PROCESSES, 0..) |pmeta, pid| {
            var proc = Process{
                .pid = .new(pid),
                .name = .new(try ctx.arena().dupe(u8, pmeta.name)),
                .cmdLine = .new(try ctx.arena().dupe(u8, pmeta.cmdline)),
            };
            if (proc_filter.matches(&proc)) {
                try procs.append(ctx.arena(), proc);
            }
        }
        return try ProcList.init(ctx, procs.items);
    }
}, .{}) = .new(.{}),

entry: zua.Shape.Modifier.Value(struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Creates an Entry at a process address.",
        .args = &.{
            .{ .name = "config", .description = "Table with pid, address, data_type." },
        },
    });
    fn impl(ctx: *zua.Context, config: EntryConfig) !Entry {
        const store = try Store.get(ctx);
        _ = store.read(ctx, config.address) catch |err| {
            return ctx.failWithFmtTyped(Entry, "invalid address: {s}", .{@errorName(err)});
        };
        const pid = config.address >> 24;
        if (pid >= PROCESSES.len) return ctx.failTyped(Entry, "invalid pid");
        const region = (config.address >> 16) & 0xFF;
        const pmeta = &PROCESSES[pid];
        if (region >= pmeta.regions.len) return ctx.failTyped(Entry, "invalid region");
        const perms = try Permissions.parseString(ctx, pmeta.regions[region].perms_str);
        return Entry{
            .pid = .new(pid),
            .address = .new(config.address),
            .perms = .new(perms),
            .data_type = config.data_type,
        };
    }
}, .{}) = .new(.{}),

docs: zua.Shape.Modifier.Value(struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Generate Lua stubs.",
    });
    fn impl(ctx: *zua.Context) ![]const u8 {
        return zua.Docs.generateGlobals(ctx.arena(), .{ .inspector = Inspector{} });
    }
}, .{}) = .new(.{}),

fn display(_: *zua.Context, _: *Inspector) []const u8 {
    return "Inspector: process-inspector example.\n" ++
        "  inspector.scan() -> procs\n" ++
        "  procs[N]:regions(\"rw-p\") -> regions\n" ++
        "  regions[N]:scan(\"i32\", {gt = 100}) -> entries\n" ++
        "  entries[N]:set(9999)";
}

const EntryConfig = struct {
    pid: usize,
    address: usize,
    data_type: DataType,

    pub const ZUA_SHAPE = zua.Shape.Table(EntryConfig, .{}, .{
        .name = "EntryConfig",
        .description = "Configuration for inspector:entry().",
        .field_descriptions = .{
            .pid = "Target process ID.",
            .address = "Memory address.",
            .data_type = "Data type: i32 or f32.",
        },
    });
};
