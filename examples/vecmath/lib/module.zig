const std = @import("std");
const zua = @import("zua");

const Vec2 = @import("vec2.zig").Vec2;
const Vec3 = @import("vec3.zig").Vec3;
// Transform is a 3x3 matrix. From Lua it looks like a nested array
// {{1,0,0},{0,1,0},{0,0,1}}.
const Transform = [3][3]f64;

// Module-level functions use the struct-with-ZUA_SHAPE pattern.
// Each struct bundles a Zig function together with its documentation
// metadata (description, args) into a single callable value.
//
// The struct has a pub const ZUA_SHAPE = Shape.Fn(impl, .{...}) that
// tells zua this struct should be pushed as a Lua function. When Lua
// calls it, zua decodes the arguments and calls the impl function.
//
// The pattern keeps the function and its docs together, and the Vecmath
// module table just stores instances of these structs.

const vec2 = struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Construct a new Vec2 value.",
        .args = &.{
            .{ .name = "x", .description = "Horizontal component." },
            .{ .name = "y", .description = "Vertical component." },
        },
    });
    fn impl(x: f64, y: f64) Vec2 { return .{ .x = x, .y = y }; }
};

const vec3 = struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Construct a new Vec3 value.",
        .args = &.{
            .{ .name = "x", .description = "X component." },
            .{ .name = "y", .description = "Y component." },
            .{ .name = "z", .description = "Z component." },
        },
    });
    fn impl(x: f64, y: f64, z: f64) Vec3 { return .{ .x = x, .y = y, .z = z }; }
};

const lerp = struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Linearly interpolate between two Vec2 values.",
        .args = &.{
            .{ .name = "a", .description = "Starting vector." },
            .{ .name = "b", .description = "Ending vector." },
            .{ .name = "t", .description = "Interpolation factor (0.0 to 1.0)." },
        },
    });
    fn impl(a: Vec2, b: Vec2, t: f64) Vec2 {
        return .{ .x = a.x + (b.x - a.x) * t, .y = a.y + (b.y - a.y) * t };
    }
};

const identity = struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Create an identity 3x3 transform matrix.",
    });
    fn impl() Transform {
        return .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    }
};

const rotate = struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Rotate a transform matrix around the Z axis.",
        .args = &.{
            .{ .name = "t", .description = "Transform matrix." },
            .{ .name = "angle", .description = "Rotation angle in radians." },
        },
    });
    fn impl(t: Transform, angle: f64) Transform {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{
            .{ t[0][0] * c + t[0][1] * s, -t[0][0] * s + t[0][1] * c, t[0][2] },
            .{ t[1][0] * c + t[1][1] * s, -t[1][0] * s + t[1][1] * c, t[1][2] },
            .{ t[2][0] * c + t[2][1] * s, -t[2][0] * s + t[2][1] * c, t[2][2] },
        };
    }
};

const scale = struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Uniformly scale a transform matrix.",
        .args = &.{
            .{ .name = "t", .description = "Transform matrix." },
            .{ .name = "factor", .description = "Scale factor." },
        },
    });
    fn impl(t: Transform, factor: f64) Transform {
        return .{
            .{ t[0][0] * factor, t[0][1] * factor, t[0][2] * factor },
            .{ t[1][0] * factor, t[1][1] * factor, t[1][2] * factor },
            .{ t[2][0] * factor, t[2][1] * factor, t[2][2] * factor },
        };
    }
};

const apply = struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Apply a transform to a Vec2.",
        .args = &.{
            .{ .name = "t", .description = "Transform matrix." },
            .{ .name = "v", .description = "Vector to transform." },
        },
    });
    fn impl(t: Transform, v: Vec2) Vec2 {
        return .{
            .x = t[0][0] * v.x + t[0][1] * v.y + t[0][2],
            .y = t[1][0] * v.x + t[1][1] * v.y + t[1][2],
        };
    }
};

const docs = struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description = "Generate editor stubs for the vecmath module.",
    });
    fn impl(ctx: *zua.Context) ![]const u8 {
        // generateModule traverses the Vecmath struct, reads each field's
        // ZUA_SHAPE metadata, and produces ---@param / ---@return stubs.
        return zua.Docs.generateModule(ctx.arena(), Vecmath{}, "vecmath");
    }
};

// Vecmath is the module table returned by require("vecmath").
//
// It uses Shape.Table with no methods and no metamethods. It is a plain
// container. Each field is a struct-with-ZUA_SHAPE instance that zua
// pushes as a Lua function. The field name in Lua matches the field name
// here: vm.vec2, vm.vec3, vm.lerp, etc.
pub const Vecmath = struct {
    pub const ZUA_SHAPE = zua.Shape.Table(Vecmath, .{}, .{ .name = "vecmath" });

    vec2: vec2 = .{},
    vec3: vec3 = .{},
    lerp: lerp = .{},
    identity: identity = .{},
    rotate: rotate = .{},
    scale: scale = .{},
    apply: apply = .{},
    docs: docs = .{},
};
