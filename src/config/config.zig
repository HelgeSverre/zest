const std = @import("std");

pub const app_name = "zest";
pub const index_filename = "index.zst";
pub const pins_filename = "pins.json";
pub const config_filename = "config.json";

/// Default directories to exclude from indexing.
pub const default_excludes = [_][]const u8{
    ".git",
    "node_modules",
    ".Trash",
    "__pycache__",
    ".DS_Store",
    ".cache",
    ".npm",
    ".yarn",
    "Library/Caches",
    "Library/Logs",
    "Library/Developer",
    ".Spotlight-V100",
    ".fseventsd",
};

/// Returns the application support directory: ~/Library/Application Support/zest/
pub fn appSupportDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.HomeNotFound;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", app_name });
}

/// Returns the config directory: ~/.config/zest/
pub fn configDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return error.HomeNotFound;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", app_name });
}

/// Returns the index file path: ~/Library/Application Support/zest/index.zst
pub fn indexPath(allocator: std.mem.Allocator) ![]const u8 {
    const support = try appSupportDir(allocator);
    defer allocator.free(support);
    return std.fs.path.join(allocator, &.{ support, index_filename });
}

/// Returns the pins file path: ~/Library/Application Support/zest/pins.json
pub fn pinsPath(allocator: std.mem.Allocator) ![]const u8 {
    const support = try appSupportDir(allocator);
    defer allocator.free(support);
    return std.fs.path.join(allocator, &.{ support, pins_filename });
}

/// Ensure the app support directory exists.
pub fn ensureAppSupportDir(allocator: std.mem.Allocator) !void {
    const dir = try appSupportDir(allocator);
    defer allocator.free(dir);
    std.fs.makeDirAbsolute(dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };
}

/// Check if a path component should be excluded from indexing.
pub fn shouldExclude(name: []const u8) bool {
    for (default_excludes) |pattern| {
        if (std.mem.eql(u8, name, pattern)) return true;
    }
    return false;
}

test "shouldExclude" {
    try std.testing.expect(shouldExclude(".git"));
    try std.testing.expect(shouldExclude("node_modules"));
    try std.testing.expect(shouldExclude(".DS_Store"));
    try std.testing.expect(!shouldExclude("src"));
    try std.testing.expect(!shouldExclude("main.zig"));
}
