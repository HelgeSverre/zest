//! Pure path predicates shared by the indexer, the C-ABI engine, and config.
//! No Io, no allocation — safe for libzest-core.
const std = @import("std");

/// True when `path` is `dir` itself or lies below it on a segment boundary
/// (`/a/b` covers `/a/b/c`, never `/a/bc`). `dir == "/"` covers every absolute path.
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
    try std.testing.expect(isPathUnder("/anything", "/"));
}
