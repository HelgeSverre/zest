const std = @import("std");
const types = @import("types.zig");

pub const FsError = error{
    NotFound,
    PermissionDenied,
    NotADirectory,
    IoError,
    OutOfMemory,
};

pub const FileSystemProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        listDir: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) FsError!types.DirListing,
        stat: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, path: []const u8) FsError!types.FileEntry,
        exists: *const fn (ctx: *anyopaque, path: []const u8) bool,
        isDir: *const fn (ctx: *anyopaque, path: []const u8) bool,
    };

    pub fn listDir(self: FileSystemProvider, allocator: std.mem.Allocator, path: []const u8) FsError!types.DirListing {
        return self.vtable.listDir(self.ptr, allocator, path);
    }

    pub fn stat(self: FileSystemProvider, allocator: std.mem.Allocator, path: []const u8) FsError!types.FileEntry {
        return self.vtable.stat(self.ptr, allocator, path);
    }

    pub fn exists(self: FileSystemProvider, path: []const u8) bool {
        return self.vtable.exists(self.ptr, path);
    }

    pub fn isDir(self: FileSystemProvider, path: []const u8) bool {
        return self.vtable.isDir(self.ptr, path);
    }
};
