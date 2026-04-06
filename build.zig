const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get reshift dependency
    const reshift_dep = b.dependency("reshift", .{
        .target = target,
        .optimize = optimize,
    });
    const reshift_mod = reshift_dep.module("reshift");

    // Library module
    const reshift_io_mod = b.addModule("reshift-io", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    reshift_io_mod.addImport("reshift", reshift_mod);

    // Examples
    const example_names = [_][]const u8{
        "echo_server",
    };

    for (example_names) |name| {
        const exe_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("reshift", reshift_mod);
        exe_mod.addImport("reshift-io", reshift_io_mod);

        const exe = b.addExecutable(.{
            .name = name,
            .root_module = exe_mod,
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(
            b.fmt("run-{s}", .{name}),
            b.fmt("Run the {s} example", .{name}),
        );
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    const test_files = [_][]const u8{
        "tests/integration_test.zig",
        "tests/kqueue_test.zig",
    };

    const test_step = b.step("test", "Run all tests");

    for (test_files) |file| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(file),
            .target = target,
            .optimize = optimize,
        });
        test_mod.addImport("reshift", reshift_mod);
        test_mod.addImport("reshift-io", reshift_io_mod);

        const t = b.addTest(.{
            .root_module = test_mod,
        });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // Benchmarks
    const bench_names = [_][]const u8{
        "kqueue_bench",
    };

    for (bench_names) |name| {
        const bench_mod = b.createModule(.{
            .root_source_file = b.path(b.fmt("bench/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });
        bench_mod.addImport("reshift", reshift_mod);
        bench_mod.addImport("reshift-io", reshift_io_mod);

        const exe = b.addExecutable(.{
            .name = name,
            .root_module = bench_mod,
        });
        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step(
            b.fmt("run-{s}", .{name}),
            b.fmt("Run the {s} benchmark", .{name}),
        );
        run_step.dependOn(&run_cmd.step);
    }
}
