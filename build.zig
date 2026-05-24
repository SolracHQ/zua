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
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    setupExamples(b, module, target, optimize);
    setupVecmathExample(b, module, target, optimize);
}

fn setupVecmathExample(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const vecmath_mod = b.createModule(.{
        .root_source_file = b.path("examples/vecmath/vecmath.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zua", .module = module },
        },
    });

    const lib = b.addLibrary(.{ .name = "vecmath", .linkage = .dynamic, .root_module = vecmath_mod });
    lib.root_module.link_libc = true;

    const install_lib = b.addInstallArtifact(lib, .{});
    b.getInstallStep().dependOn(&install_lib.step);

    const vecmath_step = b.step("example-vecmath", "Build the vecmath example dylib");
    vecmath_step.dependOn(&install_lib.step);
}

fn setupExamples(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const mod_tests = b.addTest(.{
        .root_module = module,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const examples = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "example-app-config", .path = "examples/app-config/app-config.zig" },
        .{ .name = "example-process-inspector", .path = "examples/process-inspector/process-inspector.zig" },
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

        const build_step_name = b.fmt("{s}", .{example.name});
        const build_step_desc = b.fmt("Build {s}", .{example.name});
        const build_step = b.step(build_step_name, build_step_desc);
        build_step.dependOn(&exe.step);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step_name = b.fmt("run-{s}", .{example.name});
        const run_step_desc = b.fmt("Run {s}", .{example.name});
        const run_step = b.step(run_step_name, run_step_desc);
        run_step.dependOn(&run_cmd.step);
    }

    const test_step = b.step("test", "Run tests");

    test_step.dependOn(&run_mod_tests.step);
}
