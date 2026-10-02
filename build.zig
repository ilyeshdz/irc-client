const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/lib/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "irc-client",
        .root_module = lib_module,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "irc_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app/main.zig"),
            .optimize = optimize,
            .target = target,
            .imports = &.{
                .{ .name = "irc-client", .module = lib_module },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const lib_tests = b.addTest(.{
        .root_module = lib_module,
    });

    // A run step that will run the test executables.
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const run_lib_tests = b.addRunArtifact(lib_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_lib_tests.step);
}
