const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zua", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    module.linkSystemLibrary("lua", .{});
    module.link_libc = true;

    const mod_tests = b.addTest(.{
        .root_module = module,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const examples = [_]struct {
        name: []const u8,
        path: []const u8,
    }{
        .{ .name = "example-simple-table", .path = "example/simple_table.zig" },
        .{ .name = "example-table-methods", .path = "example/table_methods.zig" },
        .{ .name = "example-simple-function", .path = "example/simple_function.zig" },
        .{ .name = "example-light-userdata", .path = "example/light_userdata.zig" },
        .{ .name = "example-results", .path = "example/results.zig" },
        .{ .name = "example-guided-tour", .path = "example/guided_tour.zig" },
        .{ .name = "example-optional-args", .path = "example/optional_args.zig" },
        .{ .name = "example-try-callback", .path = "example/try_callback.zig" },
        .{ .name = "example-decode-ergonomics", .path = "example/decode_ergonomics.zig" },
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
        exe.root_module.linkSystemLibrary("lua", .{});
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
