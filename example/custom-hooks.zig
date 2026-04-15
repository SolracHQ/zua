const std = @import("std");
const zua = @import("zua");

// Priority encodes to Lua as a string ("low", "normal", "high") and decodes
// from either a string or an integer, so Lua callers can use either form.
const Priority = enum(u8) {
    low = 0,
    normal = 1,
    high = 2,

    pub const ZUA_META = zua.Meta.Table(Priority, .{})
        .withEncode([]const u8, encodeStr)
        .withDecode(decodeStrOrInt);

    fn encodeStr(_: *zua.Context, p: Priority) []const u8 {
        return @tagName(p);
    }

    fn decodeStrOrInt(ctx: *zua.Context, primitive: zua.Mapper.Decoder.Primitive) !Priority {
        switch (primitive) {
            .string => |s| {
                inline for (std.meta.fields(Priority)) |field| {
                    if (std.mem.eql(u8, s, field.name)) return @field(Priority, field.name);
                }
                return ctx.failTyped(Priority, "unknown priority name");
            },
            .integer => |n| {
                const byte = std.math.cast(u8, n) orelse
                    return ctx.failTyped(Priority, "priority integer out of range");
                if (byte > @intFromEnum(Priority.high))
                    return ctx.failTyped(Priority, "invalid priority integer");
                return @enumFromInt(byte);
            },
            else => return ctx.failTyped(Priority, "expected string or integer for Priority"),
        }
    }
};

// Address is an object-strategy type with full userdata identity and methods.
// Its decode hook fires whenever Address is decoded as a value (T) — this includes
// standalone functions and methods with a `self: Address` receiver. Methods with
// `self: *Address` extract the raw userdata pointer directly and skip the hook,
// so those still only accept the Lua handle.
const Address = struct {
    pub const ZUA_META = zua.Meta.Object(Address, .{
        .value = getValue,
        .__tostring = toString,
    }).withDecode(decodeHook);

    inner: u64,

    pub fn getValue(self: *Address) u64 {
        return self.inner;
    }

    pub fn toString(ctx: *zua.Context, self: *Address) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena(), "0x{X}", .{self.inner}) catch
            try ctx.failTyped([]const u8, "out of memory");
    }

    fn decodeHook(ctx: *zua.Context, primitive: zua.Mapper.Decoder.Primitive) !Address {
        return switch (primitive) {
            .integer => |n| .{ .inner = @intCast(n) },
            .string => |s| blk: {
                const digits = if (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X"))
                    s[2..]
                else
                    s;
                const n = std.fmt.parseInt(u64, digits, 16) catch
                    return ctx.failTyped(Address, "invalid hex address string");
                break :blk .{ .inner = n };
            },
            .userdata => |ptr| blk: {
                const addr: *Address = @ptrCast(@alignCast(ptr.get()));
                break :blk .{ .inner = addr.inner };
            },
            else => ctx.failTyped(Address, "expected integer, hex string, or Address handle"),
        };
    }
};

// The decode hook fires when Address is decoded as a value (T).
// readAddress has `addr: Address` so the hook fires — Lua can pass an integer,
// hex string, or existing handle. getValue above has `self: *Address` so it
// extracts the raw userdata pointer and the hook is not involved.

fn makeAddress(_: *zua.Context, n: u64) Address {
    return .{ .inner = n };
}

fn defaultPriority() Priority {
    return .normal;
}

fn describePriority(ctx: *zua.Context, p: Priority) ![]const u8 {
    return std.fmt.allocPrint(
        ctx.arena(),
        "priority={s} ({})",
        .{ @tagName(p), @intFromEnum(p) },
    ) catch try ctx.failTyped([]const u8, "out of memory");
}

// Takes Address by value: the decode hook fires here, so Lua can pass an integer,
// hex string, or existing handle and Zig gets a plain Address struct either way.
fn readAddress(addr: Address) u64 {
    return addr.inner;
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.State.init(init.gpa, init.io);
    defer z.deinit();
    var executor = zua.Executor{};
    var ctx = zua.Context.init(z);
    defer ctx.deinit();

    const globals = z.globals();
    defer globals.release();

    globals.set(&ctx, "makeAddress", makeAddress);
    globals.set(&ctx, "defaultPriority", defaultPriority);
    globals.set(&ctx, "describePriority", describePriority);
    globals.set(&ctx, "readAddress", readAddress);

    try executor.execute(&ctx, .{ .code = .{ .string =
        \\-- Priority encodes as string, decodes from string or integer
        \\local p = defaultPriority()
        \\print(p)                               -- normal
        \\print(type(p))                         -- string
        \\print(describePriority("low"))         -- priority=low (0)
        \\print(describePriority("high"))        -- priority=high (2)
        \\print(describePriority(1))             -- priority=normal (1)
        \\
        \\-- Address decodes from integer, hex string, or existing handle
        \\local a = makeAddress(0xDEAD)
        \\print(tostring(a))                     -- 0xDEAD
        \\print(a:value())                       -- 57005  (method, takes *Address normally)
        \\print(readAddress(48))                 -- 48
        \\print(readAddress("0xFF"))             -- 255
        \\print(readAddress("CAFE"))             -- 51966
        \\print(readAddress(a))                  -- 57005  (passing handle to value param)
    } });
}
