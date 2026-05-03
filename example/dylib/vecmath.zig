const std = @import("std");
const zua = @import("zua");
const lua = zua.lua;

const Vec2 = struct {
    pub const ZUA_META = zua.Meta.Table(Vec2, .{
        .add = add,
        .__add = add,
        .sub = sub,
        .__sub = sub,
        .scale = scale,
        .dot = dot,
        .length = length,
        .normalize = normalize,
    }, .{});

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

fn docs(ctx: *zua.Context) ![]const u8 {
    return zua.Docs.generateModule(ctx.arena(), module, "vecmath");
}

const vec2_fn = zua.Native.new(vec2, .{}, .{
    .name = "vec2",
    .description = "Construct a new Vec2 value.",
    .args = &.{
        .{ .name = "x", .description = "Horizontal component." },
        .{ .name = "y", .description = "Vertical component." },
    },
});

const lerp_fn = zua.Native.new(lerp, .{}, .{
    .name = "lerp",
    .description = "Linearly interpolate between two Vec2 values.",
    .args = &.{
        .{ .name = "a", .description = "Starting vector." },
        .{ .name = "b", .description = "Ending vector." },
        .{ .name = "t", .description = "Interpolation factor (0.0 to 1.0)." },
    },
});

const docs_fn = zua.Native.new(docs, .{}, .{
    .name = "docs",
    .description = "Generate editor stubs for the vecmath module.",
});

const module = .{ .vec2 = vec2_fn, .lerp = lerp_fn, .docs = docs_fn };

export fn luaopen_vecmath(L: *lua.State) c_int {
    var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
    const io = threaded.io();

    const state = zua.State.libState(L, std.heap.c_allocator, io, "vecmath") catch return 0;
    var ctx = zua.Context.init(state);
    defer ctx.deinit();
    zua.Mapper.Encoder.pushValue(&ctx, module) catch return 0;
    return 1;
}
