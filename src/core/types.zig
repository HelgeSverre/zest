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

pub const SearchResult = struct {
    name: []const u8,
    dir_path: []const u8,
    size: u64,
    mtime: i64,
    kind: FileKind,
    category: FileCategory,
    score: u32,
};
