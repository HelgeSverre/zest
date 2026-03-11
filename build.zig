const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // === Binary 1: zest (GUI/CLI app) ===
    const zest = b.addExecutable(.{
        .name = "zest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zest.root_module.linkFramework("CoreServices", .{});
    zest.root_module.linkFramework("AppKit", .{});
    zest.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(zest);

    // === Binary 2: zest-indexer (background daemon) ===
    const indexer = b.addExecutable(.{
        .name = "zest-indexer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indexer_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    indexer.root_module.linkFramework("CoreServices", .{});
    indexer.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(indexer);

    // === Run step ===
    const run_step = b.step("run", "Run the zest app");
    const run_cmd = b.addRunArtifact(zest);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // === Tests ===
    // Single test root that imports all modules
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
