const std = @import("std");
const zua = @import("zua");

const Zua = zua.Zua;
const Result = zua.Result;
const ZuaFn = zua.ZuaFn;

const Entry = struct {
    pub const ZUA_META = zua.meta.Object(Entry, .{
        .get = get,
        .set = set,
        .address = getAddress,
        .__tostring = toString,
    });

    address: u64,
    value: f64,

    pub fn get(self: *Entry) Result(f64) {
        return Result(f64).ok(self.value);
    }

    pub fn set(self: *Entry, v: f64) Result(.{}) {
        self.value = v;
        return Result(.{}).ok(.{});
    }

    pub fn getAddress(self: *Entry) Result(u64) {
        return Result(u64).ok(self.address);
    }

    pub fn toString(z: *Zua, self: *Entry) Result([]const u8) {
        const display = std.fmt.allocPrint(
            z.allocator,
            "Entry(address=0x{X}, value={d})",
            .{ self.address, self.value },
        ) catch return Result([]const u8).errStatic("out of memory");
        return Result([]const u8).owned(display);
    }
};

const EntryTable = struct {
    pub const ZUA_META = zua.meta.Table(EntryTable, .{
        .get = get,
        .set = set,
    });

    address: u64,
    value: f64,

    pub fn get(self: EntryTable) Result(f64) {
        return Result(f64).ok(self.value);
    }

    pub fn set(self: zua.Table, v: f64) Result(.{}) {
        self.set("value", v);
        return Result(.{}).ok(.{});
    }
};

const Context = struct {
    pub const ZUA_META = zua.meta.Ptr(Context);

    multiplier: f64,
};

fn makeEntry(address: u64) Result(Entry) {
    return Result(Entry).ok(Entry{ .address = address, .value = 0.0 });
}

fn makeEntryAt(z: *Zua, address: u64) Result(Entry) {
    _ = z;
    return Result(Entry).ok(Entry{ .address = address, .value = 0.0 });
}

fn makeEntryTable(address: u64) Result(EntryTable) {
    return Result(EntryTable).ok(EntryTable{ .address = address, .value = 0.0 });
}

fn scaleEntry(ctx: *Context, entry: *Entry) Result(f64) {
    return Result(f64).ok(entry.value * ctx.multiplier);
}

pub fn main(init: std.process.Init) !void {
    const z = try Zua.init(init.gpa);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    globals.setFn("make_entry", ZuaFn.pure(makeEntry, .{ .parse_error = "make_entry expects (u64)" }));
    globals.setFn("make_entry_at", ZuaFn.from(makeEntryAt, .{ .parse_error = "make_entry_at expects (u64)" }));
    globals.setFn("make_entry_table", ZuaFn.pure(makeEntryTable, .{ .parse_error = "make_entry_table expects (u64)" }));
    globals.setFn("scale_entry", ZuaFn.pure(scaleEntry, .{ .parse_error = "scale_entry expects (context, entry)" }));

    var ctx = Context{ .multiplier = 3.0 };
    globals.setLightUserdata("ctx", &ctx);

    try z.exec(
        \\local e = make_entry(0)
        \\assert(type(e) == "userdata", "expected userdata, got " .. type(e))
        \\
        \\local e2 = make_entry_at(0x7fff1234)
        \\assert(type(e2) == "userdata", "expected userdata")
        \\
        \\assert(e:get() == 0.0, "expected 0.0 got " .. tostring(e:get()))
        \\
        \\e:set(8.3)
        \\assert(e:get() == 8.3, "expected 8.3 after set")
        \\
        \\assert(e2:address() == 0x7fff1234, "address mismatch: " .. tostring(e2:address()))
        \\
        \\e2:set(1.5)
        \\local s = tostring(e2)
        \\assert(s == "Entry(address=0x7FFF1234, value=1.5)", "tostring mismatch: " .. s)
        \\
        \\print("object strategy: ok")
    );

    try z.exec(
        \\local t = make_entry_table(0)
        \\assert(type(t) == "table", "expected table, got " .. type(t))
        \\
        \\assert(t.value == 0.0, "expected 0.0")
        \\assert(t.address == 0, "expected 0")
        \\
        \\assert(t:get() == 0.0, "get() mismatch")
        \\
        \\t:set(4.2)
        \\assert(t.value == 4.2, "expected 4.2 after set")
        \\assert(t:get() == 4.2, "get() after set mismatch")
        \\
        \\print("table strategy: ok")
    );

    try z.exec(
        \\assert(type(ctx) == "userdata", "expected light userdata, got " .. type(ctx))
        \\
        \\local e = make_entry(0)
        \\e:set(10.0)
        \\local scaled = scale_entry(ctx, e)
        \\assert(scaled == 30.0, "expected 30.0 got " .. tostring(scaled))
        \\
        \\print("zig_ptr strategy: ok")
    );
}
