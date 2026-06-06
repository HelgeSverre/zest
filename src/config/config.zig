const std = @import("std");
const runtime = @import("../core/runtime.zig");

pub const app_name = "zest";
pub const index_filename = "index.zst";
pub const pins_filename = "pins.json";
pub const folder_colors_filename = "folder_colors.json";
pub const filters_filename = "filters.json";
pub const config_filename = "config.json";

/// Directory/file leaf names to exclude from indexing. Matched against a single
/// path component (the dirent name), so entries here must NOT contain '/'.
/// Most dotfile entries are already covered by the dotfile skip in the walker,
/// but are kept here for explicitness and so the rule holds without that skip.
const name_excludes = std.StaticStringMap(void).initComptime(.{
    .{ ".git", {} },
    .{ "node_modules", {} },
    .{ ".Trash", {} },
    .{ "__pycache__", {} },
    .{ ".DS_Store", {} },
    .{ ".cache", {} },
    .{ ".npm", {} },
    .{ ".yarn", {} },
    .{ ".Spotlight-V100", {} },
    .{ ".fseventsd", {} },
});

/// Multi-component directory paths to exclude, matched against the *full* path
/// as a trailing path segment (e.g. any `.../Library/Caches`). These can never
/// match a single leaf name, which is why `shouldExclude(name)` missed them.
pub const path_excludes = [_][]const u8{
    "Library/Caches",
    "Library/Logs",
    "Library/Developer",
};

/// Returns the application support directory: ~/Library/Application Support/zest/
pub fn appSupportDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = runtime.getEnvVarOwned(allocator, "HOME") catch return error.HomeNotFound;
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", app_name });
}

/// Returns the config directory: ~/.config/zest/
pub fn configDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = runtime.getEnvVarOwned(allocator, "HOME") catch return error.HomeNotFound;
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

/// Returns the folder colors path: ~/Library/Application Support/zest/folder_colors.json
pub fn folderColorsPath(allocator: std.mem.Allocator) ![]const u8 {
    const support = try appSupportDir(allocator);
    defer allocator.free(support);
    return std.fs.path.join(allocator, &.{ support, folder_colors_filename });
}

/// Returns the saved filters path: ~/.config/zest/filters.json
pub fn filtersPath(allocator: std.mem.Allocator) ![]const u8 {
    const cfg = try configDir(allocator);
    defer allocator.free(cfg);
    return std.fs.path.join(allocator, &.{ cfg, filters_filename });
}

/// Returns the user config path: ~/.config/zest/config.json
pub fn configPath(allocator: std.mem.Allocator) ![]const u8 {
    const cfg = try configDir(allocator);
    defer allocator.free(cfg);
    return std.fs.path.join(allocator, &.{ cfg, config_filename });
}

/// Ensure the app support directory exists.
pub fn ensureAppSupportDir(allocator: std.mem.Allocator) !void {
    const dir = try appSupportDir(allocator);
    defer allocator.free(dir);
    try runtime.ensureDir(dir);
}

/// Check if a single path component (leaf dirent name) should be excluded.
pub fn shouldExclude(name: []const u8) bool {
    return name_excludes.has(name);
}

/// Check if a full directory path should be excluded because it ends with one
/// of `path_excludes` on a path-component boundary (e.g. ~/Library/Caches).
pub fn shouldExcludePath(path: []const u8) bool {
    for (path_excludes) |suffix| {
        if (!std.mem.endsWith(u8, path, suffix)) continue;
        // Require a '/' boundary (or exact match) so the suffix matches whole
        // components — "XLibrary/Caches" must not match "Library/Caches".
        const before = path.len - suffix.len;
        if (before == 0 or path[before - 1] == '/') return true;
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

test "shouldExcludePath" {
    try std.testing.expect(shouldExcludePath("/Users/helge/Library/Caches"));
    try std.testing.expect(shouldExcludePath("/Users/helge/Library/Developer"));
    try std.testing.expect(shouldExcludePath("/Users/helge/Library/Logs"));
    // leaf-name excludes are NOT path excludes
    try std.testing.expect(!shouldExcludePath("/Users/helge/Library/Application Support"));
    try std.testing.expect(!shouldExcludePath("/Users/helge/Documents"));
    // must match on a component boundary, not mid-component
    try std.testing.expect(!shouldExcludePath("/Users/helge/XLibrary/Caches"));
}
