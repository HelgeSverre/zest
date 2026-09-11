const std = @import("std");

pub fn build(b: *std.Build) void {
    // Match Package.swift instead of inheriting the build machine's OS minimum.
    const target = b.standardTargetOptions(.{ .default_target = .{
        .os_tag = .macos,
        .os_version_min = .{ .semver = .{ .major = 14, .minor = 0, .patch = 0 } },
    } });
    const optimize = b.standardOptimizeOption(.{});

    // FSEvents now ships as a sub-framework nested inside CoreServices. Add its
    // directory to the framework search path so `<FSEvents/FSEvents.h>` resolves
    // without dragging in the CoreServices umbrella (which breaks translate-c).
    const sdk_path = std.mem.trimEnd(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), "\n");
    const coreservices_frameworks = b.pathJoin(&.{
        sdk_path,
        "System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks",
    });

    // Version stamped into `--version` output; release.json is the single source of truth.
    const release = std.json.parseFromSlice(
        struct { version: []const u8, build: []const u8 },
        b.allocator,
        b.build_root.handle.readFileAlloc(b.graph.io, "release.json", b.allocator, .limited(4096)) catch @panic("cannot read release.json"),
        .{ .ignore_unknown_fields = true },
    ) catch @panic("release.json: expected {\"version\": \"x.y.z\", \"build\": \"n\"}");
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", release.value.version);
    build_info.addOption([]const u8, "build", release.value.build);

    // === Binary: zest-indexer (background daemon) ===
    const indexer = b.addExecutable(.{
        .name = "zest-indexer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/indexer_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    indexer.root_module.addOptions("build_info", build_info);
    indexer.root_module.addSystemFrameworkPath(.{ .cwd_relative = coreservices_frameworks });
    indexer.root_module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "System/Library/Frameworks" }) });
    indexer.root_module.addIncludePath(b.path("src/index"));
    indexer.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/lib" }) });
    // Compile SDK headers as C: translate-c cannot represent recent Mach bitfields.
    indexer.root_module.addCSourceFile(.{ .file = b.path("src/index/fsevents_bridge.c"), .flags = &.{ "-isysroot", sdk_path } });
    indexer.root_module.linkFramework("CoreServices", .{});
    indexer.root_module.linkFramework("CoreFoundation", .{});
    indexer.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(indexer);

    // === Binary: zest-query (read-only index query CLI) ===
    const query = b.addExecutable(.{
        .name = "zest-query",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/query_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    query.root_module.addOptions("build_info", build_info);
    query.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(query);

    // Leave room for codesign's LC_CODE_SIGNATURE load command. Without this,
    // Zig's x86_64 Mach-O layout can let signing overwrite the first function.
    // https://github.com/ziglang/zig/issues/23704
    for ([_]*std.Build.Step.Compile{ indexer, query }) |executable| {
        executable.headerpad_size = 0x1000;
    }

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

    const query_step = b.step("query", "Build only zest-query");
    query_step.dependOn(&b.addInstallArtifact(query, .{}).step);

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
    tests.root_module.addOptions("build_info", build_info);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_tests.step);
    // Also install the static lib so `swift test` can link against it
    // without a separate `zig build` first. The justfile runs `zig build test`
    // then `swift test` in one recipe; this keeps that sequence working.
    test_step.dependOn(b.getInstallStep());
}
