const std = @import("std");
const zua = @import("zua");
const App = @import("app.zig").App;

// Address decodes from multiple Lua representations via a hook.
// Lua callers can pass:
//
//   address = "0.0.0.0"           -- plain host
//   address = "0.0.0.0:8080"      -- host with port
//   address = {127, 0, 0, 1}      -- segmented ip as [4]u8
//
// The decode hook fires whenever zua decodes a Lua value into Address.
// It checks the primitive type and extracts host + port accordingly.

pub const Address = struct {
    host: []const u8,
    port: u16,

    pub const ZUA_SHAPE = zua.Shape.Table(Address, .{}, .{ .name = "address" })
        .withDecode(decodeHook)
        .withDocs(addressDocs);

    fn decodeHook(ctx: *zua.Context, prim: zua.Mapper.Primitive) !?Address {
        return switch (prim) {
            .string => |s| {
                if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
                    const port = try std.fmt.parseInt(u16, s[colon + 1 ..], 10);
                    return Address{ .host = try ctx.arena().dupe(u8, s[0..colon]), .port = port };
                }
                return Address{ .host = try ctx.arena().dupe(u8, s), .port = 8080 };
            },
            .table => {
                const parts = try prim.decode(ctx, [4]u8);
                const host = try std.fmt.allocPrint(ctx.arena(), "{d}.{d}.{d}.{d}", .{ parts[0], parts[1], parts[2], parts[3] });
                return Address{ .host = host, .port = 8080 };
            },
            else => return ctx.failTyped(?Address, "expected string or table of octets for address"),
        };
    }
};

// The docs hook produces an Alias entry so the stubs show what
// forms address accepts, instead of referencing an undefined type.
fn addressDocs(self: *zua.Docs.Generator) !void {
    var alias = zua.Docs.Entry.Alias{
        .name = try self.arena.allocator().dupe(u8, "address"),
        .description = try self.arena.allocator().dupe(u8, "Listen address. Accepts a string or a table of octets."),
        .values = .empty,
    };
    try alias.values.append(self.arena.allocator(), .{
        .type = try self.arena.allocator().dupe(u8, "string"),
        .description = "Host name, or \"host:port\" to include the port.",
    });
    try alias.values.append(self.arena.allocator(), .{
        .type = try self.arena.allocator().dupe(u8, "[integer, integer, integer, integer]"),
        .description = "Segmented IP as four octets.",
    });
    try self.aliases.append(self.arena.allocator(), alias);
}

// AppConfig is a table-strategy struct. Table strategy fields map 1:1
// to Lua table keys at comptime. zua reads field names and types
// directly from the struct declaration. When Lua calls makeApp({...}),
// zua decodes the table into AppConfig automatically.
//
// Every field except name is optional with a sensible default. zua
// fills in missing fields from the struct default values, so callers
// can omit address or port and get the defaults shown here.
pub const AppConfig = struct {
    pub const ZUA_SHAPE = zua.Shape.Table(AppConfig, .{}, .{
        .name = "AppConfig",
        .description = "Configuration table for makeApp.",
        .field_descriptions = .{
            .name = "Server name (required).",
            .address = "Listen address. String, \"host:port\", or {octets}.",
            .port = "Listen port. Overrides port from address.",
        },
    });

    name: []const u8,
    address: ?Address = .{ .host = "0.0.0.0", .port = 8080 },
    port: ?u16 = 8080,
};

// makeApp is a struct-with-ZUA_SHAPE. It takes a single AppConfig
// table and returns a configured App.
//
// Lua callers:
//   makeApp({ name = "my-server" })
//   makeApp({ name = "my-server", address = "0.0.0.0", port = 8080 })
//   makeApp({ name = "my-server", address = {127, 0, 0, 1} })
//
// The defaults live on AppConfig. zua fills them in when the caller
// omits a field, so config.address is always present (never null).
pub const makeApp = struct {
    pub const ZUA_SHAPE = zua.Shape.Fn(impl, .{
        .description =
        \\Create a new mock HTTP server app.
        \\Takes a single config table with name, address, and port.
        ,
        .args = &.{
            .{ .name = "config", .description = "Table with name (required), address (optional), port (optional)." },
        },
    });
    fn impl(ctx: *zua.Context, config: AppConfig) !App {
        const addr = config.address.?;
        return App{
            .name = try ctx.heap().dupe(u8, config.name),
            .host = try ctx.heap().dupe(u8, addr.host),
            .port = config.port orelse addr.port,
            .routes = .empty,
            .middlewares = .empty,
        };
    }
};
