const std = @import("std");
const builder = @import("builder.zig");
const config = @import("../config/config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

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
        // TODO: FSEvents watcher loop for incremental updates
        std.debug.print("Index built. FSEvents watcher not yet implemented.\n", .{});
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
