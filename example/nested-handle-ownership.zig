const std = @import("std");
const zua = @import("zua");

const Handlers = zua.Handlers;
const Userdata = zua.Userdata;
const Object = zua.Object;

const Leaf = struct {
    pub const ZUA_META = zua.Meta.Object(Leaf, .{
        .getId = getId,
        .getName = getName,
        .__gc = deinit,
    });

    id: i32,
    name: []const u8,

    pub fn getId(self: *Leaf) i32 {
        return self.id;
    }

    pub fn getName(self: *Leaf) []const u8 {
        return self.name;
    }

    fn deinit(self: *Leaf) void {
        _ = self;
        std.debug.print("Leaf object being released\n", .{});
    }
};

const Extra = struct {
    other: Object(Leaf),
};

const ChildGroup = struct {
    children: [5]Object(Leaf),
    extra: Extra,
};

const Root = struct {
    pub const ZUA_META = zua.Meta.Object(Root, .{
        .describe = describe,
        .__gc = deinit,
    });

    group: ChildGroup,

    pub fn describe(self: *Root, ctx: *zua.Context) ![]const u8 {
        const first_child = self.group.children[0].get();
        const extra_child = self.group.extra.other.get();
        return std.fmt.allocPrint(
            ctx.arena(),
            "root with first child={d}:{s} and extra={d}:{s}",
            .{ first_child.id, first_child.name, extra_child.id, extra_child.name },
        ) catch try ctx.failTyped([]const u8, "out of memory");
    }

    fn deinit(self: *Root) void {
        std.debug.print("Root object being released\n", .{});
        Handlers.release(Root, self.*);
    }
};

const Holder = struct {
    pub const ZUA_META = zua.Meta.Object(Holder, .{
        .__gc = deinit,
    });

    root: Object(Root),

    fn deinit(self: *Holder) void {
        std.debug.print("Holder object being released\n", .{});
        self.root.release();
    }
};

fn makeLeaf(id: i32, name: []const u8) Leaf {
    return Leaf{ .id = id, .name = name };
}

fn makeRoot(c1: Object(Leaf), c2: Object(Leaf), c3: Object(Leaf), c4: Object(Leaf), c5: Object(Leaf), extra: Object(Leaf)) Root {
    var wrapper = Root{
        .group = ChildGroup{
            .children = .{ c1, c2, c3, c4, c5 },
            .extra = Extra{ .other = extra },
        },
    };
    Handlers.takeOwnership(&wrapper);
    return wrapper;
}

fn makeHolder(_: *zua.Context, root: Object(Root)) Holder {
    var holder = Holder{ .root = root };
    Handlers.takeOwnership(&holder);
    return holder;
}

pub fn main(init: std.process.Init) !void {
    const z = try zua.State.init(init.gpa, init.io);
    defer z.deinit();

    var executor = zua.Executor{};
    var ctx = zua.Context.init(z);
    defer ctx.deinit();

    const globals = z.globals();
    defer globals.release();

    globals.set(&ctx, "make_leaf", zua.Native.new(makeLeaf, .{ .parse_err_fmt = "make_leaf expects (number, string): {s}" }));
    globals.set(&ctx, "make_root", zua.Native.new(makeRoot, .{ .parse_err_fmt = "make_root expects (leaf, leaf, leaf, leaf, leaf, leaf): {s}" }));
    globals.set(&ctx, "make_holder", zua.Native.new(makeHolder, .{ .parse_err_fmt = "make_holder expects (root): {s}" }));

    executor.execute(&ctx, .{ .code = .{ .string =
        \\local function build_and_drop()
        \\    local root = make_root(
        \\        make_leaf(1, "one"),
        \\        make_leaf(2, "two"),
        \\        make_leaf(3, "three"),
        \\        make_leaf(4, "four"),
        \\        make_leaf(5, "five"),
        \\        make_leaf(6, "extra")
        \\    )
        \\    local holder = make_holder(root)
        \\    print("created holder and root inside function")
        \\end
        \\build_and_drop()
        \\collectgarbage("collect")
        \\collectgarbage("collect")
        \\print("done")
    } }) catch {
        std.debug.print("Execution error: {s}\n", .{ctx.err.?});
    };
}
