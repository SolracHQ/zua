const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zua", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path("vendor/lua"));
    translate_c.addIncludePath(b.path("vendor/linenoise"));
    const c_mod = translate_c.createModule();
    module.addImport("c", c_mod);

    // Lua configuration

    module.link_libc = true;
    module.addIncludePath(b.path("vendor/lua"));
    module.addIncludePath(b.path("vendor/linenoise"));

    const lua_source_files = [_][]const u8{
        "vendor/lua/lapi.c",
        "vendor/lua/lauxlib.c",
        "vendor/lua/lbaselib.c",
        "vendor/lua/lcode.c",
        "vendor/lua/lcorolib.c",
        "vendor/lua/lctype.c",
        "vendor/lua/ldblib.c",
        "vendor/lua/ldebug.c",
        "vendor/lua/ldo.c",
        "vendor/lua/ldump.c",
        "vendor/lua/lfunc.c",
        "vendor/lua/lgc.c",
        "vendor/lua/llex.c",
        "vendor/lua/lmathlib.c",
        "vendor/lua/lmem.c",
        "vendor/lua/loadlib.c",
        "vendor/lua/liolib.c",
        "vendor/lua/lobject.c",
        "vendor/lua/lopcodes.c",
        "vendor/lua/loslib.c",
        "vendor/lua/lparser.c",
        "vendor/lua/lstate.c",
        "vendor/lua/lstring.c",
        "vendor/lua/lstrlib.c",
        "vendor/lua/ltable.c",
        "vendor/lua/ltablib.c",
        "vendor/lua/ltm.c",
        "vendor/lua/lundump.c",
        "vendor/lua/lutf8lib.c",
        "vendor/lua/lvm.c",
        "vendor/lua/lzio.c",
        "vendor/lua/linit.c",
    };

    for (lua_source_files) |source_file| {
        module.addCSourceFile(.{
            .file = b.path(source_file),
            .flags = &.{"-fno-sanitize=alignment"}, // lua uses u16 alignment, and zig dont like that, so I disable it for all the files, anyways is Lua, made for a lot of people smarter than me, so I trust they know what they are doing, it works, but if I committing an error please advice in an issue or a PR, thanks.
        });
    }

    // Linenoise configuration
    module.addCSourceFile(.{ .file = b.path("vendor/linenoise/linenoise.c"), .flags = &.{} });
    module.addIncludePath(b.path("vendor/linenoise"));

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
        .{ .name = "example-nested-handle-ownership", .path = "example/nested-handle-ownership.zig" },
        .{ .name = "example-custom-hooks", .path = "example/custom-hooks.zig" },
        .{ .name = "example-repl", .path = "example/repl.zig" },
        .{ .name = "example-iterable", .path = "example/iterable.zig" },
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
