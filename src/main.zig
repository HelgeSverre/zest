const std = @import("std");
const App = @import("app.zig").App;
const real_fs = @import("core/real_fs.zig");
const config = @import("config/config.zig");
const runtime = @import("core/runtime.zig");

pub fn main(init: std.process.Init) !void {
    runtime.init(init);
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var target_path: []const u8 = ".";
    var show_help = false;
    var benchmark_query: ?[]const u8 = null;
    var benchmark_list: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--benchmark")) {
            i += 1;
            if (i < args.len) {
                benchmark_query = args[i];
            } else {
                std.debug.print("error: --benchmark requires a query argument\n", .{});
                std.process.exit(1);
            }
        } else if (std.mem.eql(u8, arg, "--benchmark-list")) {
            i += 1;
            if (i < args.len) {
                benchmark_list = args[i];
            } else {
                std.debug.print("error: --benchmark-list requires an absolute folder path\n", .{});
                std.process.exit(1);
            }
        } else {
            target_path = arg;
        }
    }

    if (show_help) {
        printUsage();
        return;
    }

    const abs_path = if (std.fs.path.isAbsolute(target_path))
        try allocator.dupe(u8, target_path)
    else blk: {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.cwd().realPathFile(runtime.io, target_path, &path_buf);
        break :blk try allocator.dupe(u8, path_buf[0..n]);
    };
    defer allocator.free(abs_path);

    std.Io.Dir.accessAbsolute(runtime.io, abs_path, .{}) catch {
        std.debug.print("error: path does not exist: {s}\n", .{abs_path});
        std.process.exit(1);
    };

    var rfs = real_fs.RealFs{};
    const fs = rfs.provider();

    if (!fs.isDir(abs_path)) {
        std.debug.print("error: not a directory: {s}\n", .{abs_path});
        std.process.exit(1);
    }

    var app = try App.init(allocator, fs, abs_path);
    defer app.deinit();

    // Try to load index
    if (config.indexPath(allocator)) |idx_path| {
        defer allocator.free(idx_path);
        if (std.Io.Dir.cwd().statFile(runtime.io, idx_path, .{})) |stat| {
            if (runtime.readFileAlloc(allocator, idx_path, .unlimited)) |data| {
                app.loadIndex(data) catch {
                    allocator.free(data);
                    std.debug.print("warning: could not load index, search unavailable\n", .{});
                };
                // Store initial inode for change detection
                app.index_inode = stat.inode;
                app.last_index_check = runtime.nowNanos();
            } else |_| {}
        } else |_| {}
    } else |_| {}

    // Check for index updates (single check in CLI mode; sets up the pattern for GUI event loop)
    _ = app.checkForIndexUpdate();

    // --benchmark mode (CLI) or launch GUI
    if (benchmark_query) |query| {
        if (app.getIndexStatus() != .ready) {
            std.debug.print("error: no index loaded. Run zest-indexer --full-scan ~ first.\n", .{});
            std.process.exit(1);
        }

        const iterations: usize = 1000;
        var latencies: [1000]i128 = undefined;

        for (0..iterations) |iter| {
            const start = runtime.nowNanos();
            const results = try app.search(query, null, &.{}, "/", std.math.maxInt(u32));
            const end = runtime.nowNanos();
            latencies[iter] = end - start;
            allocator.free(results);
        }

        std.mem.sort(i128, &latencies, {}, struct {
            fn lt(_: void, a: i128, b: i128) bool {
                return a < b;
            }
        }.lt);

        const p50 = latencies[iterations / 2];
        const p99 = latencies[iterations * 99 / 100];

        var stdout_buf: [256]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(runtime.io, &stdout_buf);
        const bm_stdout = &stdout_writer.interface;
        try bm_stdout.print("Benchmark: \"{s}\" x {d} iterations\n", .{ query, iterations });
        try bm_stdout.print("  p50: {d} us\n", .{@divTrunc(p50, 1000)});
        try bm_stdout.print("  p99: {d} us\n", .{@divTrunc(p99, 1000)});
        try bm_stdout.flush();
        return;
    }

    // --benchmark-list mode (CLI): time a depth-1 folder listing (what the GUI
    // runs on every folder switch).
    if (benchmark_list) |path| {
        if (app.getIndexStatus() != .ready) {
            std.debug.print("error: no index loaded. Run zest-indexer --full-scan ~ first.\n", .{});
            std.process.exit(1);
        }

        const iterations: usize = 20;
        var latencies: [iterations]i128 = undefined;
        var count: usize = 0;
        for (0..iterations) |iter| {
            const start = runtime.nowNanos();
            const results = try app.search("", null, &.{}, path, 1);
            const end = runtime.nowNanos();
            latencies[iter] = end - start;
            count = results.len;
            allocator.free(results);
        }
        std.mem.sort(i128, &latencies, {}, struct {
            fn lt(_: void, a: i128, b: i128) bool {
                return a < b;
            }
        }.lt);
        std.debug.print("Folder-list benchmark: \"{s}\" x {d} ({d} entries)\n", .{ path, iterations, count });
        std.debug.print("  p50: {d} ms\n", .{@divTrunc(latencies[iterations / 2], std.time.ns_per_ms)});
        std.debug.print("  p99: {d} ms\n", .{@divTrunc(latencies[iterations - 1], std.time.ns_per_ms)});
        return;
    }

    // Launch GUI
    const appkit = @import("ui/appkit.zig");
    try appkit.run(allocator, &app);
}

fn printUsage() void {
    std.debug.print(
        \\Usage: zest [path]
        \\
        \\  A minimal, fast file browser for macOS.
        \\
        \\Options:
        \\  -h, --help              Show this help message
        \\  --benchmark "query"     Run search benchmark (1000 iterations, prints p50/p99)
        \\
        \\Examples:
        \\  zest .         Open current directory
        \\  zest ~/code    Open ~/code
        \\  zest /tmp      Open /tmp
        \\
    , .{});
}
