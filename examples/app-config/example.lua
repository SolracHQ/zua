-- makeApp takes a single config table. Every field except name is optional.
--   { name = "my-server" }                               -- defaults 0.0.0.0:8080
--   { name = "...", address = "0.0.0.0", port = 8080 }   -- separate host and port
--   { name = "...", address = "0.0.0.0:8080" }           -- combined with colon
--   { name = "...", address = {127, 0, 0, 1} }           -- segmented ip as table

local app = makeApp({
    name = "my-server",
    address = { 0, 0, 0, 0 },
    port = 8080,
})

-- Route handlers and middleware are Zig-typed callbacks. The stubs
-- generator picks up the types from Typed.Fn and produces proper
-- annotations (fun(Request): Response) with no extra effort. Hover
-- over the handler parameter in your editor to see it.
app:route("/api/users", "GET", function(req) return { status = 200, body = "[]" } end)
app:route("/api/posts", "POST", function(req) return { status = 201, body = "{}" } end)
app:route("/api/health", "GET", function(req) return { status = 200, body = "ok" } end)

-- Middleware gets the same treatment. The next parameter is a
-- recursively typed function: fun(req: Request): Response.
app:middleware(function(req, next)
    req.headers["X-Request-Id"] = "mock-id"
    return next(req)
end)

app:middleware(function(req, next)
    print("-->", req.method, req.path)
    local res = next(req)
    print("<--", res.status)
    return res
end)

local db = app:database("sqlite", ":memory:")
db:connect():migrate("001_users.sql")

local info = app:build()
print(info.name, info.host, info.port)
print("routes registered:", #info.routes)
for _, r in ipairs(info.routes) do
    print(" ", r.method, r.path)
end

-- Simulate requests. Each call passes a Request table to the stored
-- handler. The handler can return any Response table it wants. Zig
-- checks the shape is valid when decoding, but the content is up to
-- the Lua callback. That transparency is what Table strategy is for.
for _, route in ipairs(info.routes) do
    local res = app:simulate({ method = route.method, path = route.path, headers = {} })
    print("simulate", route.method, route.path, "->", res.status, res.body)
end
