const std = @import("std");
const types = @import("types.zig");
const fs_provider = @import("fs_provider.zig");
const file_types = @import("file_types.zig");

const FileSystemProvider = fs_provider.FileSystemProvider;
const FsError = fs_provider.FsError;

pub const RealFs = struct {
    pub fn provider(self: *RealFs) FileSystemProvider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = FileSystemProvider.VTable{
        .listDir = listDirImpl,
        .stat = statImpl,
        .exists = existsImpl,
        .isDir = isDirImpl,
    };

    fn kindFromStat(stat: std.fs.File.Stat) types.FileKind {
        return switch (stat.kind) {
            .directory => .directory,
            .sym_link => .symlink,
            else => .file,
        };
    }

    fn mtimeToEpoch(stat: std.fs.File.Stat) i64 {
        return @intCast(@divTrunc(stat.mtime, std.time.ns_per_s));
    }

    fn listDirImpl(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) FsError!types.DirListing {
        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
            return switch (err) {
                error.FileNotFound => FsError.NotFound,
                error.AccessDenied => FsError.PermissionDenied,
                error.NotDir => FsError.NotADirectory,
                else => FsError.IoError,
            };
        };
        defer dir.close();

        var entries: std.ArrayList(types.FileEntry) = .empty;
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.path);
            }
            entries.deinit(allocator);
        }

        var iter = dir.iterate();
        while (iter.next() catch return FsError.IoError) |item| {
            if (item.name.len > 0 and item.name[0] == '.') continue;

            const name = allocator.dupe(u8, item.name) catch return FsError.OutOfMemory;
            errdefer allocator.free(name);

            const full_path = std.fs.path.join(allocator, &.{ path, item.name }) catch return FsError.OutOfMemory;
            errdefer allocator.free(full_path);

            const kind: types.FileKind = switch (item.kind) {
                .directory => .directory,
                .sym_link => .symlink,
                else => .file,
            };

            var size: u64 = 0;
            var mtime: i64 = 0;

            if (dir.statFile(item.name)) |stat| {
                size = stat.size;
                mtime = mtimeToEpoch(stat);
            } else |_| {}

            const cat: types.FileCategory = if (kind == .directory) .uncategorized else file_types.categorize(name);

            entries.append(allocator, .{
                .name = name,
                .path = full_path,
                .size = size,
                .mtime = mtime,
                .kind = kind,
                .category = cat,
            }) catch return FsError.OutOfMemory;
        }

        return .{
            .entries = entries.toOwnedSlice(allocator) catch return FsError.OutOfMemory,
            .allocator = allocator,
        };
    }

    fn statImpl(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8) FsError!types.FileEntry {
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err == error.IsDir) {
                var dir = std.fs.openDirAbsolute(path, .{}) catch return FsError.NotFound;
                defer dir.close();
                const s = dir.stat() catch return FsError.IoError;
                const name = std.fs.path.basename(path);
                return .{
                    .name = allocator.dupe(u8, name) catch return FsError.OutOfMemory,
                    .path = allocator.dupe(u8, path) catch return FsError.OutOfMemory,
                    .size = 0,
                    .mtime = mtimeToEpoch(s),
                    .kind = .directory,
                    .category = .uncategorized,
                };
            }
            return switch (err) {
                error.FileNotFound => FsError.NotFound,
                error.AccessDenied => FsError.PermissionDenied,
                else => FsError.IoError,
            };
        };
        defer file.close();

        const stat = file.stat() catch return FsError.IoError;
        const name = std.fs.path.basename(path);
        const kind = kindFromStat(stat);
        const cat: types.FileCategory = if (kind == .directory) .uncategorized else file_types.categorize(name);

        return .{
            .name = allocator.dupe(u8, name) catch return FsError.OutOfMemory,
            .path = allocator.dupe(u8, path) catch return FsError.OutOfMemory,
            .size = stat.size,
            .mtime = mtimeToEpoch(stat),
            .kind = kind,
            .category = cat,
        };
    }

    fn existsImpl(_: *anyopaque, path: []const u8) bool {
        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    fn isDirImpl(_: *anyopaque, path: []const u8) bool {
        var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
        dir.close();
        return true;
    }
};
