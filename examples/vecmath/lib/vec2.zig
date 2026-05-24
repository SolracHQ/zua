const std = @import("std");
const zua = @import("zua");

// Vec2 is an object-strategy type using Shape.Object.
//
// Shape.Object stores the value as Lua userdata. Lua holds a pointer to it
// and fields are accessible through Modifier.Field markers. When a Vec2 is
// returned from Zig, zua creates a Lua userdata holding the struct. When
// a Vec2 is received from Lua (as a function argument), zua reads the
// userdata's inner struct fields and decodes them.
//
// Methods are declared in the Shape.Object call as a method set.
// __-prefixed names become Lua metamethods (__add, __sub, etc.).
// Non-prefixed names become regular methods callable with :method().
//
// zua.Shape.Fn wraps each method with documentation metadata. The
// .description and .args are consumed by the Docs stub generator.

pub const Vec2 = struct {
    // Modifier.Field marks struct fields as readable and writable from Lua.
    // zua generates __index and __newindex entries in the metatable so Lua
    // can access v.x and v.y = 5 directly.
    x: zua.Shape.Modifier.Field(f64, .{ .description = "X component." }),
    y: zua.Shape.Modifier.Field(f64, .{ .description = "Y component." }),

    pub const ZUA_SHAPE = zua.Shape.Object(Vec2, .{
        // __add and __sub take two Vec2 values and return a new one.
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
        // __mul takes a Vec2 and a scalar number.
        .__mul = zua.Shape.Fn(mul, .{
            .description = "Scalar multiplication.",
            .args = &.{
                .{ .name = "factor", .description = "Scalar factor." },
            },
        }),
        // __eq compares two Vec2 values. Returns a boolean, not a Vec2.
        // Shape.Fn is not used here. A bare fn reference is enough when
        // no documentation metadata is needed.
        .__eq = eq,
        // Named methods use :notation from Lua. zua injects the userdata
        // pointer for the self parameter automatically.
        .length = zua.Shape.Fn(length, .{ .description = "Euclidean norm." }),
        .dot = zua.Shape.Fn(dot, .{
            .description = "Dot product.",
            .args = &.{.{ .name = "b", .description = "Right vector." }},
        }),
        .normalize = zua.Shape.Fn(normalize, .{
            .description = "Unit vector, returns zeros if length is zero.",
        }),
        .__tostring = toString,
    }, .{ .name = "vec2" });

    // Object methods receive *const Vec2 (a pointer to the struct inside the
    // userdata). The .value field on Modifier.Field holds the inner f64.
    // Returning a Vec2 creates a new userdata automatically.

    fn add(self: *const Vec2, other: *const Vec2) Vec2 {
        return .{ .x = .new(self.x.value + other.x.value), .y = .new(self.y.value + other.y.value) };
    }

    fn sub(self: *const Vec2, other: *const Vec2) Vec2 {
        return .{ .x = .new(self.x.value - other.x.value), .y = .new(self.y.value - other.y.value) };
    }

    fn mul(self: *const Vec2, factor: f64) Vec2 {
        return .{ .x = .new(self.x.value * factor), .y = .new(self.y.value * factor) };
    }

    fn eq(a: *const Vec2, b: *const Vec2) bool {
        return a.x.value == b.x.value and a.y.value == b.y.value;
    }

    fn length(self: *const Vec2) f64 {
        return @sqrt(self.x.value * self.x.value + self.y.value * self.y.value);
    }

    fn dot(a: *const Vec2, b: *const Vec2) f64 {
        return a.x.value * b.x.value + a.y.value * b.y.value;
    }

    fn normalize(self: *const Vec2) Vec2 {
        const len = @sqrt(self.x.value * self.x.value + self.y.value * self.y.value);
        if (len == 0) return Vec2{ .x = .new(0), .y = .new(0) };
        return .{ .x = .new(self.x.value / len), .y = .new(self.y.value / len) };
    }

    // ctx is not special to __tostring. Any function exposed via zua can
    // have ctx as the first parameter if it needs to query the context.
    // Here we use ctx.arena() to allocate the formatted string. The arena
    // lives for the duration of the Lua callback and is freed after it
    // returns.
    fn toString(ctx: *zua.Context, self: *const Vec2) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena(), "vec2({d}, {d})", .{ self.x.value, self.y.value }) catch
            ctx.failTyped([]const u8, "oom");
    }
};
