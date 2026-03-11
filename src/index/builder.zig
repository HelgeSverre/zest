const std = @import("std");
const types = @import("../core/types.zig");
const format = @import("format.zig");
const file_types = @import("../core/file_types.zig");
const config = @import("../config/config.zig");

pub fn buildIndex(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    var entries: std.ArrayList(format.IndexEntry) = .empty;
    defer entries.deinit(allocator);

    var owned_names: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_names.items) |name| allocator.free(name);
        owned_names.deinit(allocator);
    }
    var owned_dirs: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_dirs.items) |d| allocator.free(d);
        owned_dirs.deinit(allocator);
    }

    try walkDir(allocator, root, &entries, &owned_names, &owned_dirs);

    return format.writeIndex(allocator, entries.items);
}

fn walkDir(
    allocator: std.mem.Allocator,
    path: []const u8,
    entries: *std.ArrayList(format.IndexEntry),
    owned_names: *std.ArrayList([]u8),
    owned_dirs: *std.ArrayList([]u8),
) !void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |item| {
        if (config.shouldExclude(item.name)) continue;
        if (item.name.len > 0 and item.name[0] == '.') continue;

        const name_owned = try allocator.dupe(u8, item.name);
        try owned_names.append(allocator, name_owned);

        const dir_owned = try allocator.dupe(u8, path);
        try owned_dirs.append(allocator, dir_owned);

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

        const cat: types.FileCategory = if (kind == .directory) .uncategorized else file_types.categorize(name_owned);

        try entries.append(allocator, .{
            .name = name_owned,
            .dir_path = dir_owned,
            .size = size,
            .mtime = mtime,
            .kind = kind,
            .category = cat,
        });

        if (kind == .directory) {
            const child_path = try std.fs.path.join(allocator, &.{ path, item.name });
            defer allocator.free(child_path);
            try walkDir(allocator, child_path, entries, owned_names, owned_dirs);
        }
    }
}

pub fn buildIndexFromEntries(allocator: std.mem.Allocator, entries: []const format.IndexEntry) ![]u8 {
    return format.writeIndex(allocator, entries);
}
