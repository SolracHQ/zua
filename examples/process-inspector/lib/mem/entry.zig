const std = @import("std");
const zua = @import("zua");

const Permissions = @import("../region/perms.zig").Permissions;
const DataType = @import("types.zig").DataType;
const Store = @import("../data.zig").Store;

// Entry uses Shape.Object so Lua sees an opaque userdata. Users call
// :get() and :set(value) to read and write the value at the address.
// pid, address, and perms use Modifier.Value so Lua reads them as
// fields (e.pid, e.address, e.perms) but can never write them.

pub const Entry = @This();

// Methods are declared separately from ZUA_SHAPE for readability. Any
// comptime-known struct works. const means zua resolves the whole
// decode/encode pipeline at comptime. Only ZUA_SHAPE itself must be
// pub for zua to see it; methods can stay private.
const methods = .{
    .__tostring = display,
    .get = zua.Shape.Fn(getValue, .{
        .description = "Reads the live value from memory.",
    }),
    .set = zua.Shape.Fn(setValue, .{
        .description = "Writes a new value to this address.",
        .args = &.{.{ .name = "value", .description = "Value to write." }},
    }),
};

pub const ZUA_SHAPE = zua.Shape.Object(Entry, methods, .{
    .name = "Entry",
    .description = "A typed memory value at a fixed address.",
});

pid: zua.Shape.Modifier.Value(usize, .{ .description = "Process ID." }),
address: zua.Shape.Modifier.Value(usize, .{ .description = "Memory address." }),
perms: zua.Shape.Modifier.Value(Permissions, .{ .description = "Access permissions." }),
data_type: DataType,

fn display(ctx: *zua.Context, self: *Entry) ![]const u8 {
    const t = switch (self.data_type) {
        .i32 => "i32",
        .f32 => "f32",
    };
    return std.fmt.allocPrint(ctx.arena(), "Entry({d}, 0x{x}, {s})", .{ self.pid.value, self.address.value, t });
}

fn getValue(ctx: *zua.Context, self: *Entry) !zua.Mapper.Primitive {
    const store = try Store.get(ctx);
    const raw = try store.read(ctx, self.address.value);
    return switch (self.data_type) {
        .i32 => zua.Mapper.Primitive{ .integer = raw },
        .f32 => zua.Mapper.Primitive{ .float = @as(f64, @as(f32, @bitCast(raw))) },
    };
}

fn setValue(ctx: *zua.Context, self: *Entry, value: zua.Mapper.Primitive) !void {
    if (!self.perms.value.has(.write)) {
        return ctx.failWithFmt("address 0x{x} is not writable", .{self.address.value});
    }
    const store = try Store.get(ctx);
    switch (self.data_type) {
        .i32 => {
            const v = try zua.Mapper.Decoder.decode(ctx, value, i32);
            try store.write(ctx, self.address.value, v);
        },
        .f32 => {
            const v = try zua.Mapper.Decoder.decode(ctx, value, f32);
            try store.write(ctx, self.address.value, @bitCast(v));
        },
    }
}
