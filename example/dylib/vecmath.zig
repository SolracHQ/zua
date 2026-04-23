const std = @import("std");
const zua = @import("zua");
const lua = zua.lua;

const Vec2 = struct {
    pub const ZUA_META = zua.Meta.Table(Vec2, .{
        .add = add,
        .sub = sub,
        .scale = scale,
        .dot = dot,
        .length = length,
        .normalize = normalize,
    });

    x: f64,
    y: f64,

    fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    fn scale(self: Vec2, factor: f64) Vec2 {
        return .{ .x = self.x * factor, .y = self.y * factor };
    }

    fn dot(a: Vec2, b: Vec2) f64 {
        return a.x * b.x + a.y * b.y;
    }

    fn length(self: Vec2) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    fn normalize(self: Vec2) Vec2 {
        const len = @sqrt(self.x * self.x + self.y * self.y);
        if (len == 0) return .{ .x = 0, .y = 0 };
        return .{ .x = self.x / len, .y = self.y / len };
    }
};

fn vec2(x: f64, y: f64) Vec2 {
    return .{ .x = x, .y = y };
}

fn lerp(a: Vec2, b: Vec2, t: f64) Vec2 {
    return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
}

const Module = struct {
    pub const ZUA_META = zua.Meta.Table(@This(), .{ .vec2 = zua.Native.new(vec2, .{}), .lerp = zua.Native.new(lerp, .{}) });
};

export fn luaopen_vecmath(L: *lua.State) c_int {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    const io = threaded.io();

    const state = zua.State.libState(L, std.heap.c_allocator, io, "vecmath") catch return 0;
    var ctx = zua.Context.init(state);
    defer ctx.deinit();
    zua.Mapper.Encoder.pushValue(&ctx, Module{}) catch return 0;
    return 1;
}
