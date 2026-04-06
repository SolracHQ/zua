const std = @import("std");
const zua = @import("zua");

// Example 1: Basic enum usage - encodes/decodes as integers
pub const Color = enum(u8) {
    red = 0,
    green = 1,
    blue = 2,
};

// Example 2: Enum with custom encode hook - converts to string names
pub const Status = enum(u8) {
    idle = 0,
    running = 1,
    stopped = 2,

    fn encodeAsString(status: Status) []const u8 {
        return switch (status) {
            .idle => "idle",
            .running => "running",
            .stopped => "stopped",
        };
    }

    pub const ZUA_META = zua.meta.strEnum(Status, .{})
        .withEncode([]const u8, encodeAsString);
};

// Example 3: Direction enum with custom encode
pub const Direction = enum(u8) {
    north = 0,
    east = 1,
    south = 2,
    west = 3,

    fn encodeAsString(dir: Direction) []const u8 {
        return switch (dir) {
            .north => "north",
            .east => "east",
            .south => "south",
            .west => "west",
        };
    }

    pub const ZUA_META = zua.meta.strEnum(Direction, .{})
        .withEncode([]const u8, encodeAsString);
};

// Example 4: Address type with custom decode hook
// Accepts integer (memory address) or userdata (existing handle)
pub const Address = struct {
    value: u64,

    fn decodeAddressHook(z: *zua.Zua, index: zua.lua.StackIndex, kind: zua.lua.Type) !Address {
        const value: u64 = switch (kind) {
            .number => int: {
                const int_val = zua.lua.toInteger(z.state, index) orelse return error.InvalidType;
                break :int @intCast(int_val);
            },
            .userdata => ud: {
                if (zua.lua.toUserdata(z.state, index)) |ptr| {
                    const addr_ptr: *Address = @ptrCast(@alignCast(ptr));
                    break :ud addr_ptr.value;
                }
                return error.InvalidType;
            },
            else => return error.InvalidType,
        };
        return Address{ .value = value };
    }

    pub const ZUA_META = zua.meta.Table(Address, .{})
        .withDecode(decodeAddressHook);
};

// Return types for Lua callbacks
const GetColorResult = zua.Result(Color);
const GetStatusResult = zua.Result(Status);
const GetDirectionResult = zua.Result(Direction);
const TestAddressResult = zua.Result(u64);

fn getColor(_: *zua.Zua) GetColorResult {
    return GetColorResult.ok(.green);
}

fn getStatus(_: *zua.Zua) GetStatusResult {
    return GetStatusResult.ok(.running);
}

fn getDirection(_: *zua.Zua) GetDirectionResult {
    return GetDirectionResult.ok(.north);
}

fn testAddress(_: *zua.Zua, addr: Address) TestAddressResult {
    return TestAddressResult.ok(addr.value);
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.Zua.init(init.gpa, init.io);
    defer z.deinit();

    const globals = z.globals();
    defer globals.pop();

    // Register Lua functions
    globals.setFn("get_color", zua.ZuaFn.from(getColor, .{ .parse_error = "" }));
    globals.setFn("get_status", zua.ZuaFn.from(getStatus, .{ .parse_error = "" }));
    globals.setFn("get_direction", zua.ZuaFn.from(getDirection, .{ .parse_error = "" }));
    globals.setFn("test_address", zua.ZuaFn.from(testAddress, .{ .parse_error = "test_address expects an address" }));

    // Test script that uses enums and custom hooks
    const test_script =
        \\-- Test basic enum (encoded as integer)
        \\print("Basic enum test:")
        \\local color = get_color()
        \\print("Color value:", color)
        \\
        \\-- Test enum with encode hook (converted to string)
        \\print("\nStatus enum with encode hook:")
        \\local status = get_status()
        \\print("Status:", status)
        \\print("Type:", type(status))
        \\
        \\-- Test direction enum
        \\print("\nDirection enum with encode hook:")
        \\local dir = get_direction()
        \\print("Direction:", dir)
        \\
        \\-- Test decode hook with integer input
        \\print("\nDecode hook tests:")
        \\print("Address from integer:", test_address(0xdeadbeef))
        \\
        \\print("\nAll custom hook tests passed!")
    ;

    try z.exec(test_script);
}
