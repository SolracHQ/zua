const std = @import("std");
const zua = @import("zua");

// Vec3 is the same object-strategy pattern as Vec2 with an extra component.
//
// The ZUA_SHAPE follows the same Shape.Object pattern. The main difference
// is the cross product method (only meaningful in 3D) and the three-field
// struct.
//
// Each function is documented with Shape.Fn so the docs stub generator
// produces proper ---@param annotations.

pub const Vec3 = struct {
    x: zua.Shape.Modifier.Field(f64, .{ .description = "X component." }),
    y: zua.Shape.Modifier.Field(f64, .{ .description = "Y component." }),
    z: zua.Shape.Modifier.Field(f64, .{ .description = "Z component." }),

    pub const ZUA_SHAPE = zua.Shape.Object(Vec3, .{
        .__add = zua.Shape.Fn(add, .{
            .description = "Component-wise addition.",
            .args = &.{
                .{ .name = "a", .description = "First vector." },
                .{ .name = "b", .description = "Second vector." },
            },
        }),
        .__sub = zua.Shape.Fn(sub, .{
            .description = "Component-wise subtraction.",
            .args = &.{
                .{ .name = "a", .description = "First vector." },
                .{ .name = "b", .description = "Second vector." },
            },
        }),
        .__mul = zua.Shape.Fn(mul, .{
            .description = "Scalar multiplication.",
            .args = &.{
                .{ .name = "factor", .description = "Scalar factor." },
            },
        }),
        .__eq = eq,
        .length = zua.Shape.Fn(length, .{ .description = "Euclidean norm." }),
        .dot = zua.Shape.Fn(dot, .{
            .description = "Dot product.",
            .args = &.{.{ .name = "b", .description = "Right vector." }},
        }),
        .cross = zua.Shape.Fn(cross, .{
            .description = "Cross product.",
            .args = &.{.{ .name = "b", .description = "Right vector." }},
        }),
        .normalize = zua.Shape.Fn(normalize, .{
            .description = "Unit vector, returns zeros if length is zero.",
        }),
        .__tostring = toString,
    }, .{ .name = "vec3" });

    // Object methods receive *const Vec3 (a pointer to the struct inside the
    // userdata). The .value field on Modifier.Field holds the inner f64.

    fn add(self: *const Vec3, other: *const Vec3) Vec3 {
        return .{
            .x = .new(self.x.value + other.x.value),
            .y = .new(self.y.value + other.y.value),
            .z = .new(self.z.value + other.z.value),
        };
    }

    fn sub(self: *const Vec3, other: *const Vec3) Vec3 {
        return .{
            .x = .new(self.x.value - other.x.value),
            .y = .new(self.y.value - other.y.value),
            .z = .new(self.z.value - other.z.value),
        };
    }

    fn mul(self: *const Vec3, factor: f64) Vec3 {
        return .{
            .x = .new(self.x.value * factor),
            .y = .new(self.y.value * factor),
            .z = .new(self.z.value * factor),
        };
    }

    fn eq(a: *const Vec3, b: *const Vec3) bool {
        return a.x.value == b.x.value and a.y.value == b.y.value and a.z.value == b.z.value;
    }

    fn length(self: *const Vec3) f64 {
        return @sqrt(self.x.value * self.x.value + self.y.value * self.y.value + self.z.value * self.z.value);
    }

    fn dot(a: *const Vec3, b: *const Vec3) f64 {
        return a.x.value * b.x.value + a.y.value * b.y.value + a.z.value * b.z.value;
    }

    fn cross(a: *const Vec3, b: *const Vec3) Vec3 {
        return .{
            .x = .new(a.y.value * b.z.value - a.z.value * b.y.value),
            .y = .new(a.z.value * b.x.value - a.x.value * b.z.value),
            .z = .new(a.x.value * b.y.value - a.y.value * b.x.value),
        };
    }

    fn normalize(self: *const Vec3) Vec3 {
        const len = @sqrt(self.x.value * self.x.value + self.y.value * self.y.value + self.z.value * self.z.value);
        if (len == 0) return Vec3{ .x = .new(0), .y = .new(0), .z = .new(0) };
        return Vec3{ .x = .new(self.x.value / len), .y = .new(self.y.value / len), .z = .new(self.z.value / len) };
    }

    // ctx is not special to __tostring. Any function exposed via zua can
    // have ctx as the first parameter if it needs to query the context.
    fn toString(ctx: *zua.Context, self: *const Vec3) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena(), "vec3({d}, {d}, {d})", .{ self.x.value, self.y.value, self.z.value }) catch
            ctx.failTyped([]const u8, "oom");
    }
};
