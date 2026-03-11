const std = @import("std");

pub const FileKind = enum(u8) {
    file = 0,
    directory = 1,
    symlink = 2,
};

pub const FileCategory = enum(u8) {
    uncategorized = 0,
    images = 1,
    text = 2,
    documents = 3,
    spreadsheets = 4,
    audio = 5,
    video = 6,
    code = 7,
    archives = 8,

    pub const count = 9;

    pub fn displayName(self: FileCategory) []const u8 {
        return switch (self) {
            .uncategorized => "Other",
            .images => "Images",
            .text => "Text",
            .documents => "Documents",
            .spreadsheets => "Spreadsheets",
            .audio => "Audio",
            .video => "Video",
            .code => "Code",
            .archives => "Archives",
        };
    }
};

pub const FileEntry = struct {
    name: []const u8,
    path: []const u8,
    size: u64,
    mtime: i64,
    kind: FileKind,
    category: FileCategory,

    pub fn isDirectory(self: FileEntry) bool {
        return self.kind == .directory;
    }

    pub fn isFile(self: FileEntry) bool {
        return self.kind == .file;
    }
};

pub const Pin = struct {
    name: []const u8,
    path: []const u8,
    is_default: bool,
};

pub const SearchResult = struct {
    name: []const u8,
    dir_path: []const u8,
    size: u64,
    mtime: i64,
    kind: FileKind,
    category: FileCategory,
    score: u32,
};

pub const DirListing = struct {
    entries: []FileEntry,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DirListing) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.path);
        }
        self.allocator.free(self.entries);
    }
};

pub const IndexStatus = enum {
    not_found,
    indexing,
    ready,
    stale,
};
