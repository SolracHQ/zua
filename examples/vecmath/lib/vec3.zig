const std = @import("std");
const zua = @import("zua");

// Vec3 is the same table-strategy pattern as Vec2 with an extra component.
//
// The ZUA_SHAPE follows the same Shape.Table pattern. The main difference
// is the cross product method (only meaningful in 3D) and the three-field
// struct.
//
// Each function is documented with Shape.Fn so the docs stub generator
// produces proper ---@param annotations.

pub const Vec3 = struct {
    // Table strategy fields map 1:1 to Lua table keys at comptime.
    // zua reads field names and types directly from the struct decl.
    x: f64,
    y: f64,
    z: f64,

    pub const ZUA_SHAPE = zua.Shape.Table(Vec3, .{
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

    // Functions are plain Zig functions. Parameters and return values are
    // normal Zig types. zua reads the signature at comptime and generates
    // the encode/decode paths automatically. Handlers.* are only needed
    // for in-place mutation or no-copy access.

    fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    fn mul(self: Vec3, factor: f64) Vec3 {
        return .{ .x = self.x * factor, .y = self.y * factor, .z = self.z * factor };
    }

    fn eq(a: Vec3, b: Vec3) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }

    fn length(self: Vec3) f64 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    fn dot(a: Vec3, b: Vec3) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    fn normalize(self: Vec3) Vec3 {
        const len = @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
        if (len == 0) return .{ .x = 0, .y = 0, .z = 0 };
        return .{ .x = self.x / len, .y = self.y / len, .z = self.z / len };
    }

    // ctx is not special to __tostring. Any function exposed via zua can
    // have ctx as the first parameter if it needs to query the context.
    fn toString(ctx: *zua.Context, self: Vec3) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena(), "vec3({d}, {d}, {d})", .{ self.x, self.y, self.z }) catch
            ctx.failTyped([]const u8, "oom");
    }
};
