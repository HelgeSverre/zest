const std = @import("std");
const runtime = @import("../core/runtime.zig");

pub const app_name = "zest";
pub const index_filename = "index.zst";

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

/// Returns the index file path: ~/Library/Application Support/zest/index.zst
pub fn indexPath(allocator: std.mem.Allocator) ![]const u8 {
    const support = try appSupportDir(allocator);
    defer allocator.free(support);
    return std.fs.path.join(allocator, &.{ support, index_filename });
}

/// Ensure the app support directory exists.
pub fn ensureAppSupportDir(allocator: std.mem.Allocator) !void {
    const dir = try appSupportDir(allocator);
    defer allocator.free(dir);
    try runtime.ensureDir(dir);
}

/// Check if a single path component (leaf dirent name) should be excluded.
pub fn shouldExclude(name: []const u8) bool {
    return (name.len > 0 and name[0] == '.') or name_excludes.has(name);
}

/// Apply the walker's rules to every component below the scan root. Events
/// refer to descendants (including deleted paths), so no filesystem lookup is
/// appropriate here. The explicit root itself is always allowed.
pub fn shouldExcludeDescendant(path: []const u8, root: []const u8, support: []const u8) bool {
    if (isPathUnder(path, support)) return true;
    if (!isPathUnder(path, root)) return true;
    var end = root.len;
    while (end < path.len) {
        if (path[end] == '/') end += 1;
        const start = end;
        while (end < path.len and path[end] != '/') : (end += 1) {}
        if (shouldExclude(path[start..end]) or shouldExcludePath(path[0..end])) return true;
    }
    return false;
}

test "event exclusions match descendants and preserve component boundaries" {
    const root = "/home/me";
    const support = "/home/me/Library/Application Support/zest";
    for ([_][]const u8{
        "/home/me/project/node_modules/pkg/index.js",
        "/home/me/project/.git/objects/abc",
        "/home/me/.hidden/file",
        "/home/me/project/__pycache__/file",
        "/home/me/Library/Caches/app/file",
        "/home/me/Library/Logs/app/file",
        "/home/me/Library/Developer/tool/file",
        "/home/me/Library/Application Support/zest/scan.tmp.0",
        "/home/other/file",
    }) |path| try std.testing.expect(shouldExcludeDescendant(path, root, support));
    for ([_][]const u8{
        root,                            "/home/me/normal.txt",              "/home/me/project/node_modules-old/file",
        "/home/me/XLibrary/Caches/file", "/home/me/Library/Caches-old/file", "/home/me/Library/Application Support/zest-other/file",
    }) |path| try std.testing.expect(!shouldExcludeDescendant(path, root, support));
    try std.testing.expect(!shouldExcludeDescendant("/home/me/.explicit/file", "/home/me/.explicit", support));
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

/// True when `path` is `dir` itself or lives underneath it. A bare prefix
/// match is not enough: `/a/zest-foo` must not count as under `/a/zest`.
pub fn isPathUnder(path: []const u8, dir: []const u8) bool {
    if (std.mem.eql(u8, dir, "/")) return std.mem.startsWith(u8, path, "/");
    if (!std.mem.startsWith(u8, path, dir)) return false;
    return path.len == dir.len or path[dir.len] == '/';
}

test "isPathUnder matches dir itself and children, not prefix siblings" {
    try std.testing.expect(isPathUnder("/a/zest", "/a/zest"));
    try std.testing.expect(isPathUnder("/a/zest/index.zst", "/a/zest"));
    try std.testing.expect(!isPathUnder("/a/zest-foo", "/a/zest"));
    try std.testing.expect(!isPathUnder("/a/ze", "/a/zest"));
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
