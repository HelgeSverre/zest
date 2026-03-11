const std = @import("std");
const builder = @import("builder.zig");
const config = @import("../config/config.zig");
const fsevents = @import("fsevents.zig");

const c = @cImport({
    @cInclude("CoreServices/CoreServices.h");
});

/// Accumulated FSEvents dirty paths, accessed from the run-loop callback.
var dirty_count: usize = 0;

/// FSEvents callback — just bump the dirty counter.
/// We do a full rebuild anyway, so we don't need to track individual paths.
fn onFSEvent(paths: []const []const u8) void {
    dirty_count += paths.len;
    if (dirty_count >= event_threshold) {
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
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
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        std.debug.print("error: HOME not set\n", .{});
        return error.HomeNotSet;
    };
    defer allocator.free(home);
    return std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/{s}", .{ home, plist_filename });
}

fn runLaunchctl(allocator: std.mem.Allocator, verb: []const u8, path: []const u8) !void {
    const argv: []const []const u8 = &.{ "launchctl", verb, path };
    var child = std.process.Child.init(argv, allocator);
    const result = try child.spawnAndWait();
    if (result.Exited != 0) {
        std.debug.print("warning: launchctl {s} exited with code {d}\n", .{ verb, result.Exited });
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
        if (std.fs.selfExePath(&buf)) |self_path| {
            binary_path_owned = try allocator.dupe(u8, self_path);
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
    std.fs.makeDirAbsolute(parent) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write the plist file
    const file = try std.fs.createFileAbsolute(plist_dest, .{});
    try file.writeAll(plist_content);
    file.close();

    std.debug.print("Wrote plist to {s}\n", .{plist_dest});

    // Load via launchctl
    runLaunchctl(allocator, "load", plist_dest) catch |err| {
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
    runLaunchctl(allocator, "unload", plist_dest) catch {};

    // Delete the plist file
    std.fs.deleteFileAbsolute(plist_dest) catch |err| {
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

    var watcher = try fsevents.FSEventsWatcher.init(allocator, root, onFSEvent);
    defer watcher.deinit();

    watcher.start();
    defer watcher.stop();

    std.debug.print("Watcher active. Polling for changes (rebuild every 30s or 1000+ events).\n", .{});

    var last_rebuild = std.time.nanoTimestamp();
    var last_full_rescan = last_rebuild;

    // Run indefinitely, servicing the CFRunLoop for FSEvents callbacks
    while (true) {
        // Run the CFRunLoop for up to poll_interval_s seconds.
        // This services FSEvents callbacks on this thread.
        // Returns when the timeout expires or CFRunLoopStop is called.
        _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, poll_interval_s, 0);

        const now = std.time.nanoTimestamp();
        const elapsed = now - last_rebuild;
        const since_full_rescan = now - last_full_rescan;

        const daily_rescan_due = since_full_rescan >= daily_rescan_ns;
        const should_rebuild = daily_rescan_due or
            (dirty_count >= event_threshold) or
            (dirty_count > 0 and elapsed >= rebuild_interval_ns);

        if (should_rebuild) {
            if (daily_rescan_due) {
                std.debug.print("Daily full rescan triggered ({d}h since last full rescan)...\n", .{
                    @divTrunc(since_full_rescan, 3600 * std.time.ns_per_s),
                });
            } else {
                std.debug.print("Rebuilding index ({d} events, {d}s since last rebuild)...\n", .{
                    dirty_count,
                    @divTrunc(elapsed, std.time.ns_per_s),
                });
            }

            dirty_count = 0;

            runFullScan(allocator, root) catch |err| {
                std.debug.print("error: rebuild failed: {}\n", .{err});
                continue;
            };

            const rebuild_time = std.time.nanoTimestamp();
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

    // Write to tmp file, then atomic rename
    const idx_path = try config.indexPath(allocator);
    defer allocator.free(idx_path);

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{idx_path});
    defer allocator.free(tmp_path);

    // Ensure parent directory exists
    const parent = std.fs.path.dirname(idx_path) orelse return error.NoParentDir;
    std.fs.makeDirAbsolute(parent) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write tmp
    const file = try std.fs.createFileAbsolute(tmp_path, .{});
    try file.writeAll(index_data);
    file.close();

    // Atomic rename
    std.fs.renameAbsolute(tmp_path, idx_path) catch |err| {
        std.debug.print("error: failed to rename index: {}\n", .{err});
        return err;
    };

    std.debug.print("Index built: {d} bytes at {s}\n", .{ index_data.len, idx_path });
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
