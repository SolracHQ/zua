const std = @import("std");
const testing = std.testing;
const zua = @import("../../root.zig");
const Shape = zua.Shape;

fn greetDoc(_: *zua.Context, name: []const u8) void { _ = name; }
fn addDoc(a: i32, b: i32) i32 { return a + b; }

test "Docs.generateGlobals produces non-empty stub" {
    const stub = try zua.Docs.generateGlobals(testing.allocator, .{
        .add = Shape.Fn(addDoc, .{ .description = "Adds two numbers." }),
        .greet = Shape.Fn(greetDoc, .{
            .description = "Greets someone.",
            .args = &.{.{ .name = "name", .description = "The person to greet." }},
        }),
    });
    defer testing.allocator.free(stub);

    try testing.expect(stub.len > 0);
    try testing.expect(std.mem.indexOf(u8, stub, "Adds two numbers.") != null);
    try testing.expect(std.mem.indexOf(u8, stub, "Greets someone.") != null);
}

test "Docs.generateModule produces non-empty stub" {
    const stub = try zua.Docs.generateModule(testing.allocator, .{
        .add = Shape.Fn(addDoc, .{ .description = "Adds numbers." }),
        .greet = Shape.Fn(greetDoc, .{ .description = "Greets." }),
    }, "mytest");
    defer testing.allocator.free(stub);
    try testing.expect(stub.len > 0);
}
