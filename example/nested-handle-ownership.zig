const std = @import("std");
const zua = @import("zua");

const Object = zua.Object;

const User = struct {
    pub const ZUA_META = zua.Meta.Object(User, .{
        .getId = getId,
        .getName = getName,
        .__gc = cleanup,
    }, .{});

    id: i32,
    name: []const u8,

    pub fn getId(self: *User) i32 {
        return self.id;
    }

    pub fn getName(self: *User) []const u8 {
        return self.name;
    }

    fn cleanup(ctx: *zua.Context, self: *User) void {
        std.debug.print("User {d}:{s} released\n", .{ self.id, self.name });
        ctx.heap().free(self.name);
    }
};

const UserList = struct {
    pub const ZUA_META = zua.Meta.List(UserList, UserList.getElements, .{
        .__gc = UserList.cleanup,
        .__tostring = UserList.display,
        .filter = UserList.filter,
    }, .{});

    users: std.ArrayList(zua.Object(User)),

    pub fn getElements(self: *UserList) []zua.Object(User) {
        return self.users.items;
    }

    pub fn display(ctx: *zua.Context, self: *UserList) ![]const u8 {
        return std.fmt.allocPrint(ctx.arena(), "UserList({d} users)", .{self.users.items.len}) catch ctx.failTyped([]const u8, "Out of memory");
    }

    pub fn filter(ctx: *zua.Context, self: *UserList, min_id: i32) !UserList {
        var result = std.ArrayList(zua.Object(User)).empty;
        errdefer result.deinit(ctx.heap());

        for (self.users.items) |user| {
            if (user.get().id >= min_id) {
                try result.append(ctx.heap(), user.owned());
            }
        }

        return UserList{ .users = result };
    }

    fn cleanup(ctx: *zua.Context, self: *UserList) void {
        for (self.users.items) |user| {
            user.release();
        }
        self.users.deinit(ctx.heap());
    }
};

pub fn createUserList(ctx: *zua.Context, elements: []const User) !UserList {
    var list = UserList{ .users = std.ArrayList(zua.Object(User)).empty };
    errdefer {
        for (list.users.items) |user| {
            user.release();
        }
        list.users.deinit(ctx.heap());
    }

    for (elements) |user| {
        try list.users.append(ctx.heap(), zua.Object(User).create(ctx.state, user).takeOwnership());
    }
    return list;
}

fn makeUser(ctx: *zua.Context, id: i32, name: []const u8) !User {
    const owned_name = ctx.heap().dupe(u8, name) catch return ctx.failTyped(User, "out of memory");
    return User{ .id = id, .name = owned_name };
}

fn makeUsers(ctx: *zua.Context) !UserList {
    const users = [_]User{
        try makeUser(ctx, 1, "alice"),
        try makeUser(ctx, 2, "bob"),
        try makeUser(ctx, 3, "carol"),
        try makeUser(ctx, 4, "dave"),
    };
    return try createUserList(ctx, users[0..]);
}

pub fn main(init: std.process.Init) !void {
    const state = try zua.State.init(init.gpa, init.io);
    defer state.deinit();

    var executor = zua.Executor{};
    var ctx = zua.Context.init(state);
    defer ctx.deinit();

    try state.addGlobals(&ctx, .{
        .make_users = zua.Native.new(makeUsers, .{ .parse_err_fmt = "make_users expects no arguments: {s}" }, .{}),
    });

    executor.execute(&ctx, .{ .code = .{ .string =
        \\local users = make_users()
        \\print(users)
        \\local filtered = users:filter(3)
        \\print(filtered)
        \\users = nil
        \\collectgarbage("collect")
        \\print("after clearing users: only filtered should keep user 3 and 4 alive")
        \\filtered = nil
        \\collectgarbage("collect")
        \\print("after clearing filtered: all users should be released")
    } }) catch {
        std.debug.print("Execution error: {s}\n", .{ctx.err.?});
    };
}
