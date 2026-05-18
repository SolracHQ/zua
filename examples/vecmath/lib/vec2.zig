const std = @import("std");
const zua = @import("zua");

// Vec2 is a table-strategy type using Shape.Table.
//
// Shape.Table maps Zig struct fields to Lua table keys. When a Vec2 is
// returned from Zig, zua creates a Lua table with x and y fields. When
// a Vec2 is received from Lua (as a function argument), zua reads the
// table's x and y fields and decodes them into the struct.
//
// Methods are declared in the Shape.Table call as a method set.
// __-prefixed names become Lua metamethods (__add, __sub, etc.).
// Non-prefixed names become regular methods callable with :method().
//
// zua.Shape.Fn wraps each method with documentation metadata. The
// .description and .args are consumed by the Docs stub generator.

pub const Vec2 = struct {
    // Table strategy fields map 1:1 to Lua table keys at comptime.
    // zua reads the field names and types directly from the struct
    // declaration. No registration or runtime reflection needed.
    x: f64,
    y: f64,

    pub const ZUA_SHAPE = zua.Shape.Table(Vec2, .{
        // __add and __sub take two Vec2 values and return a new one.
        // Both the metamethod (__add) and the named form (.add) are
        // registered so users can write either a + b or a:add(b).
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
        // Named methods use :notation from Lua. zua injects self as the
        // first parameter automatically based on the function signature.
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

    // Functions are plain Zig functions. Parameters and return values are
    // normal Zig types (Vec2, f64, bool, etc.). No special ceremony is
    // needed. zua reads the function signature at comptime and generates
    // the encode/decode paths automatically.
    //
    // Handlers.* are only needed when you want in-place mutation of a Lua
    // value or access without copying. For value types like Vec2, plain
    // structs are all you need.

    fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }

    fn sub(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }

    fn mul(self: Vec2, factor: f64) Vec2 {
        return .{ .x = self.x * factor, .y = self.y * factor };
    }

    fn eq(a: Vec2, b: Vec2) bool {
        return a.x == b.x and a.y == b.y;
    }

    fn length(self: Vec2) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }

    fn dot(a: Vec2, b: Vec2) f64 {
        return a.x * b.x + a.y * b.y;
    }

    fn normalize(self: Vec2) Vec2 {
        const len = @sqrt(self.x * self.x + self.y * self.y);
        if (len == 0) return .{ .x = 0, .y = 0 };
        return .{ .x = self.x / len, .y = self.y / len };
    }

    // ctx is not special to __tostring. Any function exposed via zua can
    // have ctx as the first parameter if it needs to query the context.
    // Here we use ctx.arena() to allocate the formatted string. The arena
    // lives for the duration of the Lua callback and is freed after it
    // returns.
    fn toString(ctx: *zua.Context, self: Vec2) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena(), "vec2({d}, {d})", .{ self.x, self.y }) catch
            ctx.failTyped([]const u8, "oom");
    }
};
