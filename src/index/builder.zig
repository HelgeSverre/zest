const std = @import("std");
const types = @import("../core/types.zig");
const format = @import("format.zig");
const file_types = @import("../core/file_types.zig");
const config = @import("../config/config.zig");

/// Build the index by walking the filesystem and writing entries to a temp
/// file as they are discovered. If the walk crashes partway through, the temp
/// file contains everything found so far. After the walk completes, the temp
/// file is read back and converted into the columnar index format.
pub fn buildIndex(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    // Phase 1: Walk filesystem, stream entries to temp file
    const support_dir = try config.appSupportDir(allocator);
    defer allocator.free(support_dir);
    const scan_path = try std.fmt.allocPrint(allocator, "{s}/scan.tmp", .{support_dir});
    defer allocator.free(scan_path);

    var progress = Progress{};
    {
        const file = try std.fs.createFileAbsolute(scan_path, .{});
        defer file.close();
        const writer = file.deprecatedWriter();
        try walkDir(root, writer, &progress);
    }
    progress.finish();

    // Phase 2: Read temp file back, build columnar index
    std.debug.print("  building columnar index...\n", .{});
    const index_data = try buildFromScanFile(allocator, scan_path);

    // Clean up temp file
    std.fs.deleteFileAbsolute(scan_path) catch {};

    return index_data;
}

fn buildFromScanFile(allocator: std.mem.Allocator, scan_path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(scan_path, .{});
    defer file.close();

    var entries: std.ArrayList(format.IndexEntry) = .empty;
    defer entries.deinit(allocator);

    var owned_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_strings.items) |s| allocator.free(s);
        owned_strings.deinit(allocator);
    }

    const reader = file.deprecatedReader();

    var line_buf: [8192]u8 = undefined;
    while (true) {
        const line = reader.readUntilDelimiter(&line_buf, '\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (line.len == 0) continue;

        // Parse tab-separated: name \t dir_path \t size \t mtime \t kind \t category
        var fields: [6][]const u8 = undefined;
        var field_idx: usize = 0;
        var start: usize = 0;
        for (line, 0..) |ch, i| {
            if (ch == '\t') {
                if (field_idx < 6) {
                    fields[field_idx] = line[start..i];
                    field_idx += 1;
                }
                start = i + 1;
            }
        }
        if (field_idx < 6 and start <= line.len) {
            fields[field_idx] = line[start..];
            field_idx += 1;
        }
        if (field_idx < 6) continue; // malformed line

        const name = try allocator.dupe(u8, fields[0]);
        try owned_strings.append(allocator, name);
        const dir_path = try allocator.dupe(u8, fields[1]);
        try owned_strings.append(allocator, dir_path);

        const size = std.fmt.parseInt(u64, fields[2], 10) catch 0;
        const mtime = std.fmt.parseInt(i64, fields[3], 10) catch 0;
        const kind_int = std.fmt.parseInt(u8, fields[4], 10) catch 0;
        const cat_int = std.fmt.parseInt(u8, fields[5], 10) catch 0;

        try entries.append(allocator, .{
            .name = name,
            .dir_path = dir_path,
            .size = size,
            .mtime = mtime,
            .kind = std.meta.intToEnum(types.FileKind, kind_int) catch .file,
            .category = std.meta.intToEnum(types.FileCategory, cat_int) catch .uncategorized,
        });
    }

    return format.writeIndex(allocator, entries.items);
}

const Progress = struct {
    file_count: usize = 0,
    dir_count: usize = 0,
    last_report: i128 = 0,
    start_time: i128 = 0,

    fn init(self: *Progress) void {
        const now = std.time.nanoTimestamp();
        self.start_time = now;
        self.last_report = now;
    }

    fn tick(self: *Progress, is_dir: bool) void {
        if (self.start_time == 0) self.init();
        self.file_count += 1;
        if (is_dir) self.dir_count += 1;

        const now = std.time.nanoTimestamp();
        if (now - self.last_report >= 2 * std.time.ns_per_s) {
            self.last_report = now;
            const elapsed_s = @divTrunc(now - self.start_time, std.time.ns_per_s);
            std.debug.print("  scanning... {d} files, {d} dirs ({d}s elapsed)\n", .{ self.file_count, self.dir_count, elapsed_s });
        }
    }

    fn finish(self: *Progress) void {
        if (self.start_time == 0) self.init();
        const elapsed_s = @divTrunc(std.time.nanoTimestamp() - self.start_time, std.time.ns_per_s);
        std.debug.print("  scan complete: {d} files, {d} dirs in {d}s\n", .{ self.file_count, self.dir_count, elapsed_s });
    }
};

/// Walk the directory tree and write each entry as a tab-separated line to the writer.
/// Format: name \t dir_path \t size \t mtime \t kind \t category \n
fn walkDir(path: []const u8, writer: anytype, progress: *Progress) !void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (true) {
        const maybe_item = iter.next() catch break;
        const item = maybe_item orelse break;

        if (config.shouldExclude(item.name)) continue;
        if (item.name.len > 0 and item.name[0] == '.') continue;

        const kind: types.FileKind = switch (item.kind) {
            .directory => .directory,
            .sym_link => .symlink,
            else => .file,
        };

        var size: u64 = 0;
        var mtime: i64 = 0;
        if (dir.statFile(item.name)) |stat| {
            size = stat.size;
            mtime = @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
        } else |_| {}

        const cat: types.FileCategory = if (kind == .directory) .uncategorized else file_types.categorize(item.name);

        writer.print("{s}\t{s}\t{d}\t{d}\t{d}\t{d}\n", .{
            item.name,
            path,
            size,
            mtime,
            @intFromEnum(kind),
            @intFromEnum(cat),
        }) catch {};

        progress.tick(kind == .directory);

        if (kind == .directory) {
            // Build child path on the stack if possible, fall back to heap
            var child_buf: [4096]u8 = undefined;
            const needed = path.len + 1 + item.name.len;
            if (needed <= child_buf.len) {
                @memcpy(child_buf[0..path.len], path);
                child_buf[path.len] = '/';
                @memcpy(child_buf[path.len + 1 ..][0..item.name.len], item.name);
                walkDir(child_buf[0..needed], writer, progress) catch {};
            }
            // Skip dirs with paths too long for the stack buffer
        }
    }
}

pub fn buildIndexFromEntries(allocator: std.mem.Allocator, entries: []const format.IndexEntry) ![]u8 {
    return format.writeIndex(allocator, entries);
}
