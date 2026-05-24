const zua = @import("zua");

// Route is an example of what Object opacity buys you. Because App is
// an opaque userdata, internal types like Route never need Lua docs or
// compatibility guarantees. Route lives in the Zig world (even though
// it holds a function reference). You can build any internal system
// you want from here down without thinking about ownership or breaking
// Lua users. It is Zig code running at Zig speed.
//
// The handler field uses zua.Handlers.Typed.Fn(.{Request}, Response).
// Typed.Fn declares the argument and return types at compile time.
// The Docs generator reads this metadata and produces a proper
// fun(Request): Response annotation in the Lua stubs. No separate
// documentation pass needed. The type is the documentation.
pub const Route = struct {
    method: []const u8,
    path: []const u8,
    handler: zua.Handlers.Typed.Fn(.{Request}, Response),
};

// AppInfo is a simple DTO. It lives in Lua world, designed to pass
// pure data across the boundary. Lua receives the table and can read
// it, write to it, ignore it. We do not care. It does not affect our
// system. Table is the right strategy for that.
pub const AppInfo = struct {
    pub const ZUA_SHAPE = zua.Shape.Table(AppInfo, .{}, .{
        .name = "AppInfo",
        .description = "Summary of an App configuration returned by App:build().",
        .field_descriptions = .{
            .name = "Server name.",
            .host = "Listen address.",
            .port = "Listen port.",
            .routes = "Array of registered Route tables.",
        },
    });

    name: []const u8,
    host: []const u8,
    port: u16,
    routes: []const Route,
};

// Request is a DTO just like AppInfo. Our system (mocked here) gets
// the HTTP request, checks it, cleans it up, and converts it to a
// table. What handlers or middleware do with it is not our problem.
// It must be transparent to Lua so middleware can inspect, modify, or
// forward it freely. That is the middleware's job. Table is the right
// strategy: Lua owns the data, we just decode and encode.
pub const Request = struct {
    pub const ZUA_SHAPE = zua.Shape.Table(Request, .{}, .{
        .name = "Request",
        .description = "Mock HTTP request passed to route handlers.",
    });

    method: []const u8,
    path: []const u8,
    headers: zua.Handlers.Any.Table,
};

// Response is the same idea. The system checks the return value can
// be serialized (to JSON, for example). What the content is, is up
// to the handler. Table keeps it transparent.
pub const Response = struct {
    pub const ZUA_SHAPE = zua.Shape.Table(Response, .{}, .{
        .name = "Response",
        .description = "Mock HTTP response returned by route handlers.",
    });

    status: i64,
    body: []const u8,
};
