const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // FSEvents now ships as a sub-framework nested inside CoreServices. Add its
    // directory to the framework search path so `<FSEvents/FSEvents.h>` resolves
    // without dragging in the CoreServices umbrella (which breaks translate-c).
    const sdk_path = std.mem.trimEnd(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), "\n");
    const coreservices_frameworks = b.pathJoin(&.{
        sdk_path,
        "System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks",
    });

    // === Binary 1: zest (GUI/CLI app) ===
    const zest = b.addExecutable(.{
        .name = "zest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zest.root_module.addSystemFrameworkPath(.{ .cwd_relative = coreservices_frameworks });
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
    indexer.root_module.addSystemFrameworkPath(.{ .cwd_relative = coreservices_frameworks });
    indexer.root_module.linkFramework("CoreServices", .{});
    indexer.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(indexer);

    // === Library: zest-core (C ABI for the Swift UI) ===
    // Pure-CPU engine surface (reader + search). No frameworks, no Io.
    const core_lib = b.addLibrary(.{
        .name = "zest-core",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zest_core_lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    core_lib.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(core_lib);

    // `zig build core` — build only the static library (what the Swift app links).
    const core_step = b.step("core", "Build only libzest-core.a");
    core_step.dependOn(&b.addInstallArtifact(core_lib, .{}).step);

    // Indexer-only build step (`zig build indexer`). Lets the perf-sensitive
    // justfile recipes build just the daemon in ReleaseFast without depending on
    // the GUI target.
    const indexer_step = b.step("indexer", "Build only zest-indexer");
    indexer_step.dependOn(&b.addInstallArtifact(indexer, .{}).step);

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
    // builder.zig (imported by test_root) transitively pulls in bulk_scan.zig,
    // which references the libc `getattrlistbulk` symbol.
    tests.root_module.linkSystemLibrary("c", .{});

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
}
