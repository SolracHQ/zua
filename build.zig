const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zua", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Lua dependency
    const lua_dep = b.dependency("lua", .{ .target = target, .optimize = optimize });
    const lua_lib = lua_dep.artifact("lua");
    module.link_libc = true;
    module.linkLibrary(lua_lib);

    const lua = b.addTranslateC(.{
        .root_source_file = b.path("src/lua/lua_import.h"),
        .target = target,
        .optimize = optimize,
    });
    lua.addIncludePath(lua_lib.getEmittedIncludeTree());
    const lua_mod = lua.createModule();
    module.addImport("lua", lua_mod);

    // isocline configuration
    const isocline_dep = b.dependency("isocline", .{});

    const isocline = b.addTranslateC(.{
        .root_source_file = isocline_dep.path("include/isocline.h"),
        .target = target,
        .optimize = optimize,
    });
    const isocline_mod = isocline.createModule();
    isocline_mod.addCSourceFile(.{ .file = isocline_dep.path("src/isocline.c") });
    module.addImport("isocline", isocline_mod);

    const repl = b.addExecutable(.{ .name = "zua", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "zua", .module = module }} }) });
    b.installArtifact(repl);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(repl);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    setupExamples(b, module, target, optimize);
}

fn setupExamples(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const mod_tests = b.addTest(.{
        .root_module = module,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const vecmath_module = b.createModule(.{
        .root_source_file = b.path("example/dylib/vecmath.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zua", .module = module },
        },
    });

    const lib = b.addLibrary(.{ .name = "vecmath", .linkage = .dynamic, .root_module = vecmath_module });
    lib.root_module.link_libc = true;

    const install_lib = b.addInstallArtifact(lib, .{});
    b.getInstallStep().dependOn(&install_lib.step);

    const vecmath_step = b.step("vecmath", "Build vecmath dynamic library");
    vecmath_step.dependOn(&install_lib.step);

    const examples = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "example-docs", .path = "example/docs.zig" },
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
