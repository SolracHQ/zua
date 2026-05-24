const std = @import("std");
const zua = @import("zua");
const ObjectOf = zua.Handlers.Typed.Object;

// Database is a second Object type in this example. It shows multiple
// userdata types interacting: the App spawns a Database, and each one
// has its own metatable, methods, and cleanup.
//
// Opacity matters here too. From Lua, `db` is just an opaque handle.
// The internals (db_type, path) are hidden and only accessible through
// typed Zig methods. A table would expose them for direct mutation.
//
// Methods return self so Lua code can chain:
//   db:connect():migrate("001_users.sql")

pub const Database = struct {
    pub const ZUA_SHAPE = zua.Shape.Object(Database, .{
        .connect = connect,
        .migrate = migrate,
        .__gc = cleanup,
    }, .{
        .name = "Database",
        .description =
        \\Mock database connection.
        \\Methods print what they would do.
    ,
    });

    // Fields live inside a Lua userdata block, allocated by Lua's
    // allocator. ObjectOf(Database).create allocates the block, copies
    // the struct in, and attaches the metatable. self.get() returns a
    // *Database pointing into that block. When Lua collects it, __gc
    // runs and frees any sub-allocations (the strings here).
    db_type: []const u8,
    path: []const u8,

    fn connect(_: *zua.Context, self: ObjectOf(Database)) !ObjectOf(Database) {
        const db = self.get();
        std.debug.print("[mock] connecting to {s}:{s}\n", .{ db.db_type, db.path });
        return self;
    }

    fn migrate(_: *zua.Context, self: ObjectOf(Database), file: []const u8) !ObjectOf(Database) {
        std.debug.print("[mock] running migration {s}\n", .{file});
        return self;
    }

    // Every heap allocation needs a matching free. __gc is where
    // Database frees its strings. If you skip this, the debug
    // allocator will report leaks on exit.
    fn cleanup(ctx: *zua.Context, self: *Database) void {
        ctx.heap().free(self.db_type);
        ctx.heap().free(self.path);
    }
};
