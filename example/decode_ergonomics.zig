const std = @import("std");
const zua = @import("zua");

const Zua = zua.Zua;
const Result = zua.Result;
const Table = zua.Table;

const Range = struct {
    min: f64,
    max: f64,
};

const Condition = union(enum) {
    eq: f64,
    in_range: Range,
};

const ProcListOptions = struct {
    name: ?[]const u8,
};

const ScanRequest = struct {
    type_name: []const u8,
    condition: Condition,
};

const RescanRequest = struct {
    condition: Condition,
};

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    const proc_api = z.createTable(0, 1);
    defer proc_api.pop();
    proc_api.setFn("list", zua.ZuaFn.from(listProcesses, "proc.list expects an optional options table"));
    globals.set("proc", proc_api);

    try z.exec(
        \\local p = proc.list({ name = "target" })[1]
        \\local entries = p:scan({ type = "f32", eq = 8.3 })
        \\local ranged = p:scan({ type = "u32", in_range = { min = 0, max = 255 } })
        \\entries = entries:rescan({ eq = 9.0 })
        \\ranged = ranged:rescan({ in_range = { min = 1.0, max = 10.0 } })
        \\print(entries[1]:get())
        \\entries[1]:set(9.0)
        \\print(entries[1]:get())
        \\print(ranged[1]:get())
    );
}

fn listProcesses(z: *Zua, options_table: ?Table) Result(Table) {
    const options = if (options_table) |options|
        zua.translation.decodeStruct(Table, options, ProcListOptions) catch return Result(Table).errStatic("proc.list options are invalid")
    else
        ProcListOptions{ .name = null };

    if (options.name) |name| {
        if (!std.mem.eql(u8, name, "target")) {
            const empty = z.createTable(0, 0);
            return Result(Table).ok(empty);
        }
    }

    const list = z.createTable(1, 0);
    const process = buildProcessTable(z, "target");
    defer process.pop();
    list.set(1, process);
    return Result(Table).ok(list);
}

fn processScan(z: *Zua, _: Table, options: Table) Result(Table) {
    const request = decodeScanRequest(options) catch return Result(Table).errStatic("process.scan options are invalid");
    const value = switch (request.condition) {
        .eq => |target| target,
        .in_range => |range| (range.min + range.max) / 2.0,
    };

    const entries = buildEntryList(z, request.type_name, value);
    return Result(Table).ok(entries);
}

fn entryListRescan(z: *Zua, _: Table, options: Table) Result(Table) {
    const request = decodeRescanRequest(options) catch return Result(Table).errStatic("entries.rescan options are invalid");
    const value = switch (request.condition) {
        .eq => |target| target,
        .in_range => |range| (range.min + range.max) / 2.0,
    };

    const entries = buildEntryList(z, "rescan", value);
    return Result(Table).ok(entries);
}

fn entryGet(self: Table) Result(f64) {
    const value = self.get("value", f64) catch return Result(f64).errStatic("entry.value missing");
    return Result(f64).ok(value);
}

fn entrySet(self: Table, value: f64) Result(.{}) {
    self.set("value", value);
    return Result(.{}).ok(.{});
}

fn buildProcessTable(z: *Zua, name: []const u8) Table {
    const process = z.createTable(0, 2);
    process.set("name", name);
    process.setFn("scan", zua.ZuaFn.from(processScan, "process.scan expects (self, options)"));
    return process;
}

fn buildEntryList(z: *Zua, type_name: []const u8, value: f64) Table {
    const entries = z.createTable(1, 1);
    entries.setFn("rescan", zua.ZuaFn.from(entryListRescan, "entries.rescan expects (self, options)"));

    const entry = z.createTable(0, 4);
    defer entry.pop();
    entry.set("type", type_name);
    entry.set("value", value);
    entry.setFn("get", zua.ZuaFn.pure(entryGet, "entry.get expects self"));
    entry.setFn("set", zua.ZuaFn.pure(entrySet, "entry.set expects (self, value)"));

    entries.set(1, entry);
    return entries;
}

fn decodeScanRequest(table: Table) anyerror!ScanRequest {
    const Raw = struct {
        type: []const u8,
        eq: ?f64,
        in_range: ?Range,
    };

    const raw = try zua.translation.decodeStruct(Table, table, Raw);
    return .{
        .type_name = raw.type,
        .condition = try decodeCondition(raw.eq, raw.in_range),
    };
}

fn decodeRescanRequest(table: Table) anyerror!RescanRequest {
    const Raw = struct {
        eq: ?f64,
        in_range: ?Range,
    };

    const raw = try zua.translation.decodeStruct(Table, table, Raw);
    return .{
        .condition = try decodeCondition(raw.eq, raw.in_range),
    };
}

fn decodeCondition(eq: ?f64, in_range: ?Range) anyerror!Condition {
    if (eq != null and in_range != null) return error.InvalidValueType;
    if (eq) |value| return .{ .eq = value };
    if (in_range) |range| return .{ .in_range = range };
    return error.InvalidValueType;
}
