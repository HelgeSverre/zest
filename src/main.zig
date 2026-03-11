const std = @import("std");
const App = @import("app.zig").App;
const real_fs = @import("core/real_fs.zig");
const config = @import("config/config.zig");
const types_mod = @import("core/types.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var target_path: []const u8 = ".";
    var show_help = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
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
        const cwd = try std.fs.cwd().realpathAlloc(allocator, target_path);
        break :blk cwd;
    };
    defer allocator.free(abs_path);

    std.fs.accessAbsolute(abs_path, .{}) catch {
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
        if (std.fs.openFileAbsolute(idx_path, .{})) |file| {
            defer file.close();
            const stat = try file.stat();
            const data = try allocator.alloc(u8, stat.size);
            const bytes_read = try file.readAll(data);
            if (bytes_read == stat.size) {
                app.loadIndex(data) catch {
                    allocator.free(data);
                    std.debug.print("warning: could not load index, search unavailable\n", .{});
                };
            } else {
                allocator.free(data);
            }
        } else |_| {}
    } else |_| {}

    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.print("\n  Zest — {s}\n\n", .{app.currentPath()});

    const pins = app.getPins();
    if (pins.len > 0) {
        try stdout.writeAll("  Pinned:\n");
        for (pins) |pin| {
            const marker: []const u8 = if (pin.is_default) " " else "*";
            try stdout.print("  {s} {s: <12} {s}\n", .{ marker, pin.name, pin.path });
        }
        try stdout.writeByte('\n');
    }

    var listing = app.getCurrentEntries() catch |err| {
        try stdout.print("  Error: {}\n", .{err});
        return;
    };
    defer listing.deinit();

    std.mem.sort(types_mod.FileEntry, listing.entries, {}, struct {
        fn lessThan(_: void, a: types_mod.FileEntry, b: types_mod.FileEntry) bool {
            if (a.isDirectory() != b.isDirectory()) return a.isDirectory();
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);

    try stdout.print("  {s: <30} {s: <10} {s}\n", .{ "Name", "Size", "Type" });
    try stdout.writeAll("  ");
    for (0..52) |_| try stdout.writeByte('-');
    try stdout.writeByte('\n');

    for (listing.entries) |entry| {
        const icon: []const u8 = if (entry.isDirectory()) "📁 " else "📄 ";
        const size_str = formatSize(entry.size, entry.isDirectory());
        try stdout.print("  {s}{s: <27} {s: <10} {s}\n", .{
            icon,
            truncateName(entry.name, 27),
            size_str,
            entry.category.displayName(),
        });
    }

    const index_status = app.getIndexStatus();
    try stdout.print("\n  Index: {s}\n\n", .{switch (index_status) {
        .ready => "loaded",
        .not_found => "not found (run zest-indexer --full-scan ~ to build)",
        .indexing => "building...",
        .stale => "stale",
    }});
}

fn formatSize(size: u64, is_dir: bool) []const u8 {
    if (is_dir) return "--";
    if (size == 0) return "0 B";
    if (size < 1024) return "< 1 KB";
    if (size < 1024 * 1024) return "KB";
    if (size < 1024 * 1024 * 1024) return "MB";
    return "GB";
}

fn truncateName(name: []const u8, max: usize) []const u8 {
    if (name.len <= max) return name;
    return name[0..max];
}

fn printUsage() void {
    std.debug.print(
        \\Usage: zest [path]
        \\
        \\  A minimal, fast file browser for macOS.
        \\
        \\Options:
        \\  -h, --help    Show this help message
        \\
        \\Examples:
        \\  zest .         Open current directory
        \\  zest ~/code    Open ~/code
        \\  zest /tmp      Open /tmp
        \\
    , .{});
}
