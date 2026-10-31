const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe_optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = exe_optimize,
        .scheduler_metrics = false,
    });

    const exe = b.addExecutable(.{
        .name = "geoip-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = exe_optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addImport("zio", zio.module("zio"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe_unit_tests.root_module.addImport("zio", zio.module("zio"));
    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    const download_step = b.step("download-db", "Download GeoLite2-City.mmdb database from MaxMind");
    const download_exe = b.addExecutable(.{
        .name = "download-mmdb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/download_mmdb.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const download_cmd = b.addRunArtifact(download_exe);
    download_step.dependOn(&download_cmd.step);
}
