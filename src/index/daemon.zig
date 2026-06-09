const std = @import("std");
const builder = @import("builder.zig");
const config = @import("../config/config.zig");
const fsevents = @import("fsevents.zig");
const runtime = @import("../core/runtime.zig");
const humanize = @import("../core/humanize.zig");

const c = @cImport({
    // Only CFRunLoop is needed here, which lives in CoreFoundation. Avoid the
    // CoreServices umbrella, whose `<AE/AE.h>` include breaks Zig 0.16's
    // translate-c (see fsevents.zig).
    @cInclude("CoreFoundation/CoreFoundation.h");
});

/// Accumulated FSEvents dirty paths. Bumped from the run-loop callback and
/// read/reset from the watch loop; atomic so the access is well-defined even if
/// FSEvents ever delivers the callback off the run-loop thread.
var dirty_count = std.atomic.Value(usize).init(0);

/// FSEvents callback — just bump the dirty counter.
/// We do a full rebuild anyway, so we don't need to track individual paths.
fn onFSEvent(paths: []const []const u8) void {
    const total = dirty_count.fetchAdd(paths.len, .monotonic) + paths.len;
    if (total >= event_threshold) {
        // Poke the run loop so CFRunLoopRunInMode returns early
        c.CFRunLoopStop(c.CFRunLoopGetCurrent());
    }
}

const poll_interval_s: f64 = 2.0; // CFRunLoop poll interval
const rebuild_interval_ns: i128 = 30 * std.time.ns_per_s; // 30 seconds
const daily_rescan_ns: i128 = 24 * 3600 * std.time.ns_per_s; // 24 hours
const event_threshold: usize = 1000;

const plist_label = "dev.zest.indexer";
const plist_filename = plist_label ++ ".plist";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Check for subcommands
    if (args.len >= 2) {
        if (std.mem.eql(u8, args[1], "install")) {
            return install(allocator, args);
        } else if (std.mem.eql(u8, args[1], "uninstall")) {
            return uninstall(allocator);
        }
    }

    var full_scan = false;
    var scan_root: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--full-scan")) {
            full_scan = true;
        } else {
            scan_root = arg;
        }
    }

    // Default to $HOME
    const home = runtime.getEnvVarOwned(allocator, "HOME") catch {
        std.debug.print("error: HOME not set\n", .{});
        return;
    };
    defer allocator.free(home);

    const root = scan_root orelse home;

    try config.ensureAppSupportDir(allocator);

    if (full_scan) {
        try runFullScan(allocator, root);
    } else {
        // Default: full scan then watch for changes
        try runFullScan(allocator, root);
        try runWatchLoop(allocator, root);
    }
}

fn plistPath(allocator: std.mem.Allocator) ![]u8 {
    const home = runtime.getEnvVarOwned(allocator, "HOME") catch {
        std.debug.print("error: HOME not set\n", .{});
        return error.HomeNotSet;
    };
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/{s}", .{ home, plist_filename });
}

fn runLaunchctl(verb: []const u8, path: []const u8) !void {
    const argv: []const []const u8 = &.{ "launchctl", verb, path };
    var child = try std.process.spawn(runtime.io, .{ .argv = argv });
    const term = try child.wait(runtime.io);
    switch (term) {
        .exited => |code| if (code != 0) {
            std.debug.print("warning: launchctl {s} exited with code {d}\n", .{ verb, code });
        },
        else => std.debug.print("warning: launchctl {s} terminated abnormally\n", .{verb}),
    }
}

fn install(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Determine binary path: --binary-path override or self exe path
    var binary_path_owned: ?[]u8 = null;
    defer if (binary_path_owned) |p| allocator.free(p);

    var binary_path: []const u8 = "/usr/local/bin/zest-indexer";

    var has_override = false;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--binary-path")) {
            i += 1;
            if (i < args.len) {
                binary_path = args[i];
                has_override = true;
            } else {
                std.debug.print("error: --binary-path requires an argument\n", .{});
                return;
            }
        }
    }

    // Try to detect self exe path if no override was given
    if (!has_override) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.process.executablePath(runtime.io, &buf)) |len| {
            binary_path_owned = try allocator.dupe(u8, buf[0..len]);
            binary_path = binary_path_owned.?;
        } else |_| {}
    }

    // Generate plist content
    const plist_content = try generatePlist(allocator, binary_path);
    defer allocator.free(plist_content);

    // Determine plist destination
    const plist_dest = try plistPath(allocator);
    defer allocator.free(plist_dest);

    // Ensure LaunchAgents directory exists
    const parent = std.fs.path.dirname(plist_dest) orelse return error.NoParentDir;
    try runtime.ensureDir(parent);

    // Write the plist file
    try runtime.writeFileAbsolute(plist_dest, plist_content);

    std.debug.print("Wrote plist to {s}\n", .{plist_dest});

    // Load via launchctl
    runLaunchctl("load", plist_dest) catch |err| {
        std.debug.print("error: launchctl load failed: {}\n", .{err});
        return err;
    };

    std.debug.print("zest-indexer daemon installed and loaded.\n", .{});
    std.debug.print("Binary: {s}\n", .{binary_path});
}

fn uninstall(allocator: std.mem.Allocator) !void {
    const plist_dest = try plistPath(allocator);
    defer allocator.free(plist_dest);

    // Unload via launchctl (ignore errors if not loaded)
    runLaunchctl("unload", plist_dest) catch {};

    // Delete the plist file
    std.Io.Dir.deleteFileAbsolute(runtime.io, plist_dest) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("Plist not found at {s}, nothing to remove.\n", .{plist_dest});
            return;
        }
        std.debug.print("error: failed to delete plist: {}\n", .{err});
        return err;
    };

    std.debug.print("zest-indexer daemon uninstalled.\n", .{});
    std.debug.print("Removed {s}\n", .{plist_dest});
}

/// Start FSEvents watcher and run an indefinite loop that rebuilds the index
/// when enough events accumulate or enough time has passed.
fn runWatchLoop(allocator: std.mem.Allocator, root: []const u8) !void {
    std.debug.print("Starting FSEvents watcher on {s}...\n", .{root});

    var watcher: fsevents.FSEventsWatcher = undefined;
    try watcher.init(allocator, root, onFSEvent);
    defer watcher.deinit();

    watcher.start();
    defer watcher.stop();

    std.debug.print("Watcher active. Polling for changes (rebuild every 30s or 1000+ events).\n", .{});

    var last_rebuild = runtime.nowNanos();
    var last_full_rescan = last_rebuild;

    // Run indefinitely, servicing the CFRunLoop for FSEvents callbacks
    while (true) {
        // Run the CFRunLoop for up to poll_interval_s seconds.
        // This services FSEvents callbacks on this thread.
        // Returns when the timeout expires or CFRunLoopStop is called.
        _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, poll_interval_s, 0);

        const now = runtime.nowNanos();
        const elapsed = now - last_rebuild;
        const since_full_rescan = now - last_full_rescan;

        const dc = dirty_count.load(.monotonic);
        const daily_rescan_due = since_full_rescan >= daily_rescan_ns;
        const should_rebuild = daily_rescan_due or
            (dc >= event_threshold) or
            (dc > 0 and elapsed >= rebuild_interval_ns);

        if (should_rebuild) {
            if (daily_rescan_due) {
                std.debug.print("Daily full rescan triggered ({d}h since last full rescan)...\n", .{
                    @divTrunc(since_full_rescan, 3600 * std.time.ns_per_s),
                });
            } else {
                std.debug.print("Rebuilding index ({d} events, {d}s since last rebuild)...\n", .{
                    dc,
                    @divTrunc(elapsed, std.time.ns_per_s),
                });
            }

            dirty_count.store(0, .monotonic);

            runFullScan(allocator, root) catch |err| {
                std.debug.print("error: rebuild failed: {}\n", .{err});
                continue;
            };

            const rebuild_time = runtime.nowNanos();
            last_rebuild = rebuild_time;
            if (daily_rescan_due) {
                last_full_rescan = rebuild_time;
            }
        }
    }
}

fn runFullScan(allocator: std.mem.Allocator, root: []const u8) !void {
    std.debug.print("Building index for {s}...\n", .{root});

    const index_data = try builder.buildIndex(allocator, root);
    defer allocator.free(index_data);

    const idx_path = try config.indexPath(allocator);
    defer allocator.free(idx_path);

    // Ensure parent directory exists
    const parent = std.fs.path.dirname(idx_path) orelse return error.NoParentDir;
    try runtime.ensureDir(parent);

    // Durable, atomic publish: write into a uniquely-named temp in the same
    // directory, fsync it, then rename over the index. The unique temp name
    // avoids the fixed-".tmp" collision two indexer processes would hit, and the
    // fsync closes the torn-index-on-power-loss window the plain write left open.
    const t_write = runtime.nowNanos();
    runtime.writeFileAtomic(idx_path, index_data) catch |err| {
        std.debug.print("error: failed to write index: {}\n", .{err});
        return err;
    };

    var write_buf: [16]u8 = undefined;
    var size_buf: [16]u8 = undefined;
    std.debug.print("  timing: write={s}\n", .{
        humanize.duration(&write_buf, @divTrunc(runtime.nowNanos() - t_write, std.time.ns_per_ms)),
    });
    std.debug.print("Index built: {s} at {s}\n", .{ humanize.bytes(&size_buf, index_data.len), idx_path });
}

/// Generate a launchd plist for the indexer daemon.
pub fn generatePlist(allocator: std.mem.Allocator, binary_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Label</key>
        \\    <string>dev.zest.indexer</string>
        \\    <key>ProgramArguments</key>
        \\    <array>
        \\        <string>{s}</string>
        \\    </array>
        \\    <key>RunAtLoad</key>
        \\    <true/>
        \\    <key>KeepAlive</key>
        \\    <true/>
        \\    <key>ProcessType</key>
        \\    <string>Background</string>
        \\    <key>LowPriorityIO</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    , .{binary_path});
}
