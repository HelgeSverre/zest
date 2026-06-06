//! C ABI over the Zig index engine for the Swift UI. Pure CPU: the caller
//! (Swift) mmaps the index file and passes the bytes; we borrow them for the
//! Core's lifetime. No Io, no global runtime state — there is no Zig `main` here.
const std = @import("std");
const reader_mod = @import("../index/reader.zig");
const search_mod = @import("../index/search.zig");

const alloc = std.heap.c_allocator;

const Core = struct {
    reader: reader_mod.IndexReader,
};

const Query = struct {
    results: []search_mod.SearchResult,
};

pub const ZestStr = extern struct {
    ptr: [*]const u8,
    len: usize,
};

/// C-ABI row. Swift consumes this exact layout via the Clang-imported
/// `zest_core.h` (no hand-written mirror), so the layout cannot drift. Trailing
/// padding after `kind`/`category` to the 8-byte boundary is standard C ABI.
pub const ZestRow = extern struct {
    name: ZestStr,
    dir_path: ZestStr,
    size: u64,
    mtime: i64,
    kind: u8,
    category: u8,
};

fn zstr(s: []const u8) ZestStr {
    return .{ .ptr = s.ptr, .len = s.len };
}

/// Open an index from caller-owned, caller-kept-alive bytes (a Swift mmap).
/// Returns null on a malformed index. Borrows `index_bytes` until `zest_close`.
export fn zest_open(index_bytes: [*]const u8, len: usize) ?*Core {
    const core = alloc.create(Core) catch return null;
    core.* = .{
        .reader = reader_mod.IndexReader.init(alloc, index_bytes[0..len]) catch {
            alloc.destroy(core);
            return null;
        },
    };
    return core;
}

export fn zest_close(core: *Core) void {
    core.reader.deinit();
    alloc.destroy(core);
}

/// Run one query. `scope_root` "" or "/" means the whole index. `max_depth` 1 =
/// direct children (folder listing), large = subtree. Returns null on error.
/// `query_utf8` is used verbatim — the caller trims whitespace.
export fn zest_query(
    core: *Core,
    query_utf8: [*:0]const u8,
    scope_root: [*:0]const u8,
    max_depth: u32,
    max_results: u32,
) ?*Query {
    const scope_in = std.mem.span(scope_root);
    const scope = if (scope_in.len == 0) "/" else scope_in;
    const results = search_mod.search(alloc, &core.reader, .{
        .query = std.mem.span(query_utf8),
        .scope = scope,
        .max_depth = max_depth,
        .max_results = max_results,
    }) catch return null;
    const q = alloc.create(Query) catch {
        alloc.free(results);
        return null;
    };
    q.* = .{ .results = results };
    return q;
}

export fn zest_query_count(q: *const Query) usize {
    return q.results.len;
}

/// Row `i`'s strings borrow into the index mmap — valid until `zest_query_free`
/// AND while the Core's bytes stay mapped. Swift copies them immediately.
export fn zest_query_row(q: *const Query, i: usize) ZestRow {
    if (i >= q.results.len) return std.mem.zeroes(ZestRow);
    const r = q.results[i];
    return .{
        .name = zstr(r.name),
        .dir_path = zstr(r.dir_path),
        .size = r.size,
        .mtime = r.mtime,
        .kind = @intFromEnum(r.kind),
        .category = @intFromEnum(r.category),
    };
}

export fn zest_query_free(q: *Query) void {
    alloc.free(q.results);
    alloc.destroy(q);
}

test "zest_open returns null on malformed bytes" {
    const garbage = [_]u8{ 0, 1, 2, 3 };
    try std.testing.expect(zest_open(&garbage, garbage.len) == null);
}
