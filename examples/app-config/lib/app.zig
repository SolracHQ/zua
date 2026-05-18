const std = @import("std");
const zua = @import("zua");
const ObjectOf = zua.Handlers.Typed.Object;
const Route = @import("router.zig").Route;
const AppInfo = @import("router.zig").AppInfo;
const Request = @import("router.zig").Request;
const Response = @import("router.zig").Response;
const Database = @import("database.zig").Database;

const Middleware = zua.Handlers.Typed.Fn(.{ Request, zua.Handlers.Typed.Fn(.{Request}, Response) }, Response);

// App uses Object (userdata) to draw an architectural boundary.
// The critical path (routing, headers, responses) runs entirely in
// Zig. Lua configures the server and supplies handler callbacks, but
// never reaches into internals. Object enforces this: Lua sees an
// opaque handle, not a table of fields it can corrupt. The only way
// in is through Zig methods that check types and state.
//
// Object also solves ownership. Tables can hold pointers via the ptr
// strategy, but Lua users can shallow-copy the table or move the
// pointer around, causing double frees. Object pins the allocation
// to a single userdata with a known __gc that runs exactly once.

// Shape.Object creates a Lua userdata type. Every method declared here
// becomes a :method() callable from Lua. zua injects the userdata pointer
// as the first function parameter (ObjectOf(App)), so Zig methods receive
// a typed handle instead of a raw Lua state index.
//
// Each method is wrapped in zua.Shape.Fn which pairs the Zig
// implementation with documentation metadata (description, args).
// The Docs generator consumes this metadata to produce ---@param
// annotations automatically.
pub const App = struct {
    pub const ZUA_SHAPE = zua.Shape.Object(App, .{
        .listen = zua.Shape.Fn(listen, .{
            .description = "Set the listen address and port.",
            .args = &.{
                .{ .name = "host", .description = "Listen address." },
                .{ .name = "port", .description = "Listen port." },
            },
        }),
        .route = zua.Shape.Fn(route, .{
            .description = "Register a route with path, method, and handler.",
            .args = &.{
                .{ .name = "path", .description = "URL path." },
                .{ .name = "method", .description = "HTTP method (GET, POST, etc.)." },
                .{ .name = "handler", .description = "Handler function(req) -> res." },
            },
        }),
        .middleware = zua.Shape.Fn(middleware, .{
            .description = "Register a middleware function.",
            .args = &.{
                .{ .name = "handler", .description = "Middleware function(req, next) -> res." },
            },
        }),
        .database = zua.Shape.Fn(databaseFn, .{
            .description = "Create a mock database connection.",
            .args = &.{
                .{ .name = "db_type", .description = "Database type (sqlite, etc.)." },
                .{ .name = "path", .description = "Connection path." },
            },
        }),
        .build = zua.Shape.Fn(build, .{
            .description = "Return a summary table of the current configuration.",
        }),
        .simulate = zua.Shape.Fn(simulate, .{
            .description = "Simulate a request through the middleware chain.",
            .args = &.{
                .{ .name = "request", .description = "Table with method and path fields." },
            },
        }),
        .__gc = cleanup,
    }, .{
        .name = "App",
        .description =
        \\Mock HTTP server builder.
        \\Configure routes, middleware, and databases,
        \\then call :build() for a summary.
        ,
    });

    // Object structs live inside a Lua userdata block, allocated by
    // Lua's allocator. self.get() returns a *App pointing into that
    // block. Lifecycle is clear: when Lua gc collects the userdata,
    // __gc runs and frees any sub-allocations (strings, ArrayLists).
    // No Lua get/set overhead, no risk of Lua corrupting the fields.
    name: []const u8,
    host: []const u8,
    port: u16,
    routes: std.ArrayList(Route),
    middlewares: std.ArrayList(Middleware),

    // Methods return self (ObjectOf(App)) so Lua calls chain together:
    //   app:route(...):middleware(...):build()
    // zua decodes each argument from Lua and encodes the return value
    // back. ObjectOf(App) is a typed userdata handle that gets pushed
    // and popped as an opaque userdata block.
    fn listen(ctx: *zua.Context, self: ObjectOf(App), host: []const u8, port: u16) !ObjectOf(App) {
        const app = self.get();
        ctx.heap().free(app.host);
        app.host = try ctx.heap().dupe(u8, host);
        app.port = port;
        return self;
    }

    fn route(ctx: *zua.Context, self: ObjectOf(App), path: []const u8, method: []const u8, handler: zua.Handlers.Typed.Fn(.{Request}, Response)) !ObjectOf(App) {
        const app = self.get();
        const owned_path = try ctx.heap().dupe(u8, path);
        const owned_method = try ctx.heap().dupe(u8, method);
        const owned_handler = handler.takeOwnership();
        try app.routes.append(ctx.heap(), .{
            .method = owned_method,
            .path = owned_path,
            .handler = owned_handler,
        });
        return self;
    }

    fn middleware(ctx: *zua.Context, self: ObjectOf(App), handler: Middleware) !ObjectOf(App) {
        const owned = handler.takeOwnership();
        try self.get().middlewares.append(ctx.heap(), owned);
        return self;
    }

    // databaseFn creates a second Object type (Database) and returns it
    // to Lua. ObjectOf(Database).create allocates a new userdata, copies
    // the struct into it, registers the Database metatable (with __gc),
    // and returns the handle. The caller gets back an opaque userdata
    // with its own methods and lifecycle independent of App.
    fn databaseFn(ctx: *zua.Context, _: ObjectOf(App), db_type: []const u8, path: []const u8) !ObjectOf(Database) {
        return ObjectOf(Database).create(ctx.state, .{
            .db_type = try ctx.heap().dupe(u8, db_type),
            .path = try ctx.heap().dupe(u8, path),
        });
    }

    fn build(ctx: *zua.Context, self: ObjectOf(App)) !AppInfo {
        const app = self.get();
        return AppInfo{
            .name = app.name,
            .host = app.host,
            .port = app.port,
            .routes = try ctx.arena().dupe(Route, app.routes.items),
        };
    }

    // simulate runs the full middleware chain then calls the matching
    // route handler. A NextClosure tracks the chain state (middlware
    // index, fallback handler) and passes itself as the "next" argument
    // to each middleware so the chain unwinds correctly.
    fn simulate(ctx: *zua.Context, self: ObjectOf(App), req: Request) !Response {
        const app = self.get();
        for (app.routes.items) |rt| {
            if (std.mem.eql(u8, rt.method, req.method) and std.mem.eql(u8, rt.path, req.path)) {
                if (app.middlewares.items.len > 0) {
                    return try app.middlewares.items[0].function.call(ctx, .{ req, NextClosure{ .index = 1, .middlewares = app.middlewares.items, .handler = rt.handler } }, Response);
                }
                return try rt.handler.call(ctx, .{req});
            }
        }
        return ctx.failWithFmtTyped(Response, "no matching route for {s} {s}", .{ req.method, req.path });
    }

    // __gc runs when Lua collects the App userdata. Every heap
    // allocation (strings, ArrayLists, owned function references) is
    // freed here. Without __gc, the debug allocator would report
    // leaks on every run.
    fn cleanup(ctx: *zua.Context, self: *App) void {
        for (self.routes.items) |r| {
            r.handler.release();
            ctx.heap().free(r.method);
            ctx.heap().free(r.path);
        }
        self.routes.deinit(ctx.heap());
        for (self.middlewares.items) |m| m.release();
        self.middlewares.deinit(ctx.heap());
        ctx.heap().free(self.name);
        ctx.heap().free(self.host);
    }
};

// NextClosure is a Shape.Closure type. Unlike Shape.Fn which wraps a
// Zig function, Shape.Closure creates a Lua closure that carries Zig
// state (the index, middleware list, and final handler). Each time
// middleware calls next(req), Lua invokes this closure. The tick
// function either advances to the next middleware or calls the route
// handler.
//
// Closure state lives in a Lua upvalue, not in a table. The upvalue
// is opaque to Lua. Middleware cannot inspect or modify the chain
// state. NextClosure is never exposed as a named type in the stubs.
const NextClosure = struct {
    pub const ZUA_SHAPE = zua.Shape.Closure(@This(), tick, null, .{});

    index: usize,
    middlewares: []const Middleware,
    handler: zua.Handlers.Typed.Fn(.{Request}, Response),

    fn tick(ctx: *zua.Context, self: zua.Handlers.Typed.Closure(NextClosure), req: Request) !Response {
        const inner = self.get();
        if (inner.index < inner.middlewares.len) {
            const mw = inner.middlewares[inner.index];
            inner.index += 1;
            return try mw.function.call(ctx, .{ req, self }, Response);
        }
        return try inner.handler.call(ctx, .{req});
    }
};
