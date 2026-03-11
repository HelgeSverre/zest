const std = @import("std");
const types = @import("types.zig");
const fs_provider = @import("fs_provider.zig");
const file_types = @import("file_types.zig");

const FileSystemProvider = fs_provider.FileSystemProvider;
const FsError = fs_provider.FsError;

pub const FakeEntry = struct {
    name: []const u8,
    path: []const u8,
    size: u64,
    mtime: i64,
    kind: types.FileKind,
};

pub const FakeFs = struct {
    entries: std.StringHashMap(std.ArrayList(FakeEntry)),
    all_paths: std.StringHashMap(FakeEntry),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) FakeFs {
        return .{
            .entries = std.StringHashMap(std.ArrayList(FakeEntry)).init(allocator),
            .all_paths = std.StringHashMap(FakeEntry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FakeFs) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.entries.deinit();
        self.all_paths.deinit();
    }

    pub fn addDir(self: *FakeFs, path: []const u8) !void {
        const name = std.fs.path.basename(path);
        const parent = std.fs.path.dirname(path) orelse "/";

        const entry = FakeEntry{
            .name = name,
            .path = path,
            .size = 0,
            .mtime = 1710000000,
            .kind = .directory,
        };
        try self.all_paths.put(path, entry);

        const gop = try self.entries.getOrPut(parent);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.allocator, entry);

        // Ensure the directory itself has an entry list (even if empty)
        const gop2 = try self.entries.getOrPut(path);
        if (!gop2.found_existing) {
            gop2.value_ptr.* = .empty;
        }
    }

    pub fn addFile(self: *FakeFs, path: []const u8, size: u64) !void {
        const name = std.fs.path.basename(path);
        const parent = std.fs.path.dirname(path) orelse "/";

        const entry = FakeEntry{
            .name = name,
            .path = path,
            .size = size,
            .mtime = 1710000000,
            .kind = .file,
        };
        try self.all_paths.put(path, entry);

        const gop = try self.entries.getOrPut(parent);
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(self.allocator, entry);
    }

    pub fn provider(self: *FakeFs) FileSystemProvider {
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

    fn listDirImpl(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) FsError!types.DirListing {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        const children = self.entries.get(path) orelse return FsError.NotFound;

        var result = allocator.alloc(types.FileEntry, children.items.len) catch return FsError.OutOfMemory;
        for (children.items, 0..) |fake, i| {
            const cat: types.FileCategory = if (fake.kind == .directory) .uncategorized else file_types.categorize(fake.name);
            result[i] = .{
                .name = allocator.dupe(u8, fake.name) catch return FsError.OutOfMemory,
                .path = allocator.dupe(u8, fake.path) catch return FsError.OutOfMemory,
                .size = fake.size,
                .mtime = fake.mtime,
                .kind = fake.kind,
                .category = cat,
            };
        }
        return .{ .entries = result, .allocator = allocator };
    }

    fn statImpl(ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) FsError!types.FileEntry {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        const fake = self.all_paths.get(path) orelse return FsError.NotFound;
        const cat: types.FileCategory = if (fake.kind == .directory) .uncategorized else file_types.categorize(fake.name);
        return .{
            .name = allocator.dupe(u8, fake.name) catch return FsError.OutOfMemory,
            .path = allocator.dupe(u8, fake.path) catch return FsError.OutOfMemory,
            .size = fake.size,
            .mtime = fake.mtime,
            .kind = fake.kind,
            .category = cat,
        };
    }

    fn existsImpl(ctx: *anyopaque, path: []const u8) bool {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        return self.all_paths.contains(path);
    }

    fn isDirImpl(ctx: *anyopaque, path: []const u8) bool {
        const self: *FakeFs = @ptrCast(@alignCast(ctx));
        const entry = self.all_paths.get(path) orelse return false;
        return entry.kind == .directory;
    }
};
