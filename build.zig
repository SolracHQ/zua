const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zua", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    module.link_libc = true;
    module.addIncludePath(b.path("lua"));

    const lua_source_files = [_][]const u8{
        "lua/lapi.c",
        "lua/lauxlib.c",
        "lua/lbaselib.c",
        "lua/lcode.c",
        "lua/lcorolib.c",
        "lua/lctype.c",
        "lua/ldblib.c",
        "lua/ldebug.c",
        "lua/ldo.c",
        "lua/ldump.c",
        "lua/lfunc.c",
        "lua/lgc.c",
        "lua/llex.c",
        "lua/lmathlib.c",
        "lua/lmem.c",
        "lua/loadlib.c",
        "lua/liolib.c",
        "lua/lobject.c",
        "lua/lopcodes.c",
        "lua/loslib.c",
        "lua/lparser.c",
        "lua/lstate.c",
        "lua/lstring.c",
        "lua/lstrlib.c",
        "lua/ltable.c",
        "lua/ltablib.c",
        "lua/ltm.c",
        "lua/lundump.c",
        "lua/lutf8lib.c",
        "lua/lvm.c",
        "lua/lzio.c",
        "lua/linit.c",
    };

    for (lua_source_files) |source_file| {
        module.addCSourceFile(.{
            .file = b.path(source_file),
            .flags = &.{"-fno-sanitize=alignment"}, // lua uses u16 alignment, and zig dont like that, so I disable it for all the files, anyways is Lua, made for a lot of people smarter than me, so I trust they know what they are doing, it works, but if I committing an error please advice in an issue or a PR, thanks.
        });
    }

    const mod_tests = b.addTest(.{
        .root_module = module,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const examples = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "example-introduction", .path = "example/introduction.zig" },
        .{ .name = "example-functions", .path = "example/functions.zig" },
        .{ .name = "example-data-structures", .path = "example/data-structures.zig" },
        .{ .name = "example-custom-types", .path = "example/custom-types.zig" },
        .{ .name = "example-guided-tour", .path = "example/guided-tour.zig" },
        .{ .name = "example-object-slices", .path = "example/object-slices.zig" },
    };

    const examples_step = b.step("examples", "Build example programs");
    for (examples) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zua", .module = module },
                },
            }),
        });
        exe.root_module.link_libc = true;
        examples_step.dependOn(&exe.step);

        const run_cmd = b.addRunArtifact(exe);
        const run_step_name = b.fmt("run-{s}", .{example.name});
        const run_step_desc = b.fmt("Run {s}", .{example.name});
        const run_step = b.step(run_step_name, run_step_desc);
        run_step.dependOn(&run_cmd.step);
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
