//! C ABI over the Zig index engine for the Swift UI. Pure CPU: the caller
//! (Swift) mmaps the index file and passes the bytes; we borrow them for the
//! Core's lifetime. No Io, no global runtime state — there is no Zig `main` here.
const std = @import("std");
const types = @import("../core/types.zig");
const reader_mod = @import("../index/reader.zig");
const subtree_mod = @import("../index/subtree.zig");
const search_mod = @import("../index/search.zig");
const filters_mod = @import("../core/filters.zig");

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

/// Total number of entries in the index (every file + directory). Drives the
/// status bar's "files indexed" count. Cheap: a header field read.
export fn zest_count(core: *Core) usize {
    return @intCast(core.reader.numEntries());
}

/// Run one query. `scope_root` "" or "/" means the whole index. `max_depth` 1 =
/// direct children (folder listing), large = subtree. Returns null on error.
/// The query string is parsed for `cat:`/`ext:`/`kind:`/`size:`/etc qualifiers —
/// plain text and filters are routed separately to the search engine so
/// qualifiers never match as literal text.
export fn zest_query(
    core: *Core,
    query_utf8: [*:0]const u8,
    scope_root: [*:0]const u8,
    max_depth: u32,
    max_results: u32,
) ?*Query {
    const scope_in = std.mem.span(scope_root);
    const scope = if (scope_in.len == 0) "/" else scope_in;
    const raw_query = std.mem.span(query_utf8);

    // Parse qualifiers out of the raw string. On parse failure (e.g. the
    // qualifier value is malformed), fall back to a plain text search so a
    // typo never blackholes the result set.
    var parsed = filters_mod.parse(alloc, raw_query) catch {
        const results = search_mod.search(alloc, &core.reader, .{
            .query = raw_query,
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
    };
    defer parsed.deinit();

    const results = search_mod.search(alloc, &core.reader, .{
        .query = parsed.text,
        .filters = parsed.filters_list,
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

/// 9-element per-category count array. Returned by `zest_histogram` for the
/// sidebar's per-folder read. Field order matches `core.FileCategory`.
pub const ZestHistogram = extern struct {
    counts: [types.FileCategory.count]u32,
};

/// Return the per-category counts for the given scope. O(1) for
/// `max_depth == 1` (per-folder block read); O(D) for deeper scopes
/// (subtree sum across the deduplicated dir table). Directories not in the
/// index return all zeros.
export fn zest_histogram(
    core: *Core,
    scope_utf8: [*:0]const u8,
    max_depth: u32,
) ZestHistogram {
    const scope_in = std.mem.span(scope_utf8);
    const scope = if (scope_in.len == 0) "/" else scope_in;
    var result: ZestHistogram = .{ .counts = .{0} ** types.FileCategory.count };

    if (max_depth == 1) {
        // Direct children of `scope`: one read of the per-folder block.
        if (core.reader.findDirId(scope)) |dir_id| {
            core.reader.getFolderHistogram(dir_id, &result.counts);
        }
    } else {
        // Subtree of `scope` (or everything, for `scope == "/"`).
        subtree_mod.computeHistogram(core.reader, scope, &result.counts);
    }
    return result;
}

/// One (ext name, count) row. `name` is NUL-padded but NOT NUL-terminated —
/// use the `len` returned by the call. Fixed size so the Swift side can
/// stack-allocate the breakdown struct without a heap round-trip.
pub const ZestExtCount = extern struct {
    name: [16]u8,
    count: u32,
};

/// Per-(dir, cat) extension breakdown. `entries[0..len]` are the top-N ext
/// rows for the requested scope/category, sorted by count descending. Rows
/// beyond `len` are zero. Capped at 32 because the underlying bucket is too.
pub const ZestExtBreakdown = extern struct {
    entries: [32]ZestExtCount,
    len: u32,
};

/// Return the top-N extensions for the (scope, category) pair. `out` is
/// caller-allocated, length ≥ `max`. Returns the number of rows actually
/// written (≤ `max`, ≤ 32). For `max_depth == 1`, reads the per-folder bucket
/// directly (O(1) amortized — walks past earlier buckets in the column to
/// find the target). For deeper scopes, merges all buckets in the subtree
/// (O(D), hashmap temp). Buckets are already sorted by count desc on disk,
/// but the subtree merge sorts the merged result too. Directories not in
/// the index return 0 rows.
export fn zest_ext_breakdown(
    core: *Core,
    scope_utf8: [*:0]const u8,
    max_depth: u32,
    cat: u8,
    max: u32,
    out: [*]ZestExtCount,
) u32 {
    const scope_in = std.mem.span(scope_utf8);
    const scope = if (scope_in.len == 0) "/" else scope_in;
    const cap: usize = @intCast(@min(max, 32));
    if (cap == 0) return 0;
    if (cat >= types.FileCategory.count) return 0;

    // Reader returns self-owned ExtCount rows (fixed-size name + count),
    // so we can just copy them out without borrowing any reader-internal
    // storage.
    var scratch: [32]reader_mod.IndexReader.ExtCount = undefined;
    const actual: usize = if (max_depth == 1) blk: {
        const dir_id = core.reader.findDirId(scope) orelse break :blk 0;
        break :blk core.reader.getFolderExtBreakdown(dir_id, cat, scratch[0..cap]);
    } else blk: {
        break :blk subtree_mod.computeExtBreakdown(core.reader, scope, cat, scratch[0..cap], alloc);
    };

    var i: usize = 0;
    while (i < actual) : (i += 1) {
        const n: usize = scratch[i].name_len;
        @memcpy(out[i].name[0..n], scratch[i].name[0..n]);
        for (out[i].name[n..]) |*b| b.* = 0;
        out[i].count = scratch[i].count;
    }
    return @intCast(actual);
}

test "zest_open returns null on malformed bytes" {
    const garbage = [_]u8{ 0, 1, 2, 3 };
    try std.testing.expect(zest_open(&garbage, garbage.len) == null);
}

// ---------------------------------------------------------------------------
// Query-parsing regression tests. Pre-fix, `cat:code` was treated as literal
// text and zero rows matched (the file "app.zig" is the only `.code` entry in
// the fixture, and no file is literally named "cat:code"). Post-fix the
// qualifier is routed to the filter path and the row is returned.
// ---------------------------------------------------------------------------

const format = @import("../index/format.zig");

const test_entries = [_]format.IndexEntry{
    .{ .name = "report.pdf", .dir_path = "/home/user/docs", .size = 2 * 1024 * 1024, .mtime = 1700000000, .kind = .file, .category = .documents },
    .{ .name = "photo.jpg", .dir_path = "/home/user/pics", .size = 500 * 1024, .mtime = 1700100000, .kind = .file, .category = .images },
    .{ .name = "notes.txt", .dir_path = "/home/user/docs", .size = 1024, .mtime = 1700200000, .kind = .file, .category = .text },
    .{ .name = "src", .dir_path = "/home/user", .size = 0, .mtime = 1700300000, .kind = .directory, .category = .uncategorized },
    .{ .name = "report_v2.pdf", .dir_path = "/home/user/docs", .size = 5 * 1024 * 1024, .mtime = 1700400000, .kind = .file, .category = .documents },
    .{ .name = "app.zig", .dir_path = "/home/user/src", .size = 8192, .mtime = 1700500000, .kind = .file, .category = .code },
};

test "zest_query routes cat: to the filter path" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    const q = zest_query(core, "cat:code", "/", std.math.maxInt(u32), 100) orelse return error.QueryFailed;
    defer zest_query_free(q);

    try std.testing.expectEqual(@as(usize, 1), zest_query_count(q));
    const row = zest_query_row(q, 0);
    try std.testing.expectEqualStrings("app.zig", row.name.ptr[0..row.name.len]);
}

test "zest_query combines text with cat: filter (narrows to nothing)" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    // "report" as text + cat:code filter -> no file is both named "report" and
    // in the .code category. Pre-fix this returned 1 row (the text "cat:code"
    // was treated literally and matched "report" twice).
    const q = zest_query(core, "cat:code report", "/", std.math.maxInt(u32), 100) orelse return error.QueryFailed;
    defer zest_query_free(q);

    try std.testing.expectEqual(@as(usize, 0), zest_query_count(q));
}

test "zest_query routes kind:folder to the filter path" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    const q = zest_query(core, "kind:folder", "/", std.math.maxInt(u32), 100) orelse return error.QueryFailed;
    defer zest_query_free(q);

    try std.testing.expectEqual(@as(usize, 1), zest_query_count(q));
    const row = zest_query_row(q, 0);
    try std.testing.expectEqualStrings("src", row.name.ptr[0..row.name.len]);
}

test "zest_query routes ext:pdf to the filter path" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    const q = zest_query(core, "ext:pdf", "/", std.math.maxInt(u32), 100) orelse return error.QueryFailed;
    defer zest_query_free(q);

    try std.testing.expectEqual(@as(usize, 2), zest_query_count(q));
}

test "zest_query plain text still works" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    const q = zest_query(core, "report", "/", std.math.maxInt(u32), 100) orelse return error.QueryFailed;
    defer zest_query_free(q);

    try std.testing.expectEqual(@as(usize, 2), zest_query_count(q));
}

test "zest_query empty query with no scope returns nothing" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    const q = zest_query(core, "", "/", std.math.maxInt(u32), 100) orelse return error.QueryFailed;
    defer zest_query_free(q);

    try std.testing.expectEqual(@as(usize, 0), zest_query_count(q));
}

// ---------------------------------------------------------------------------
// Per-folder × per-category histogram tests. Pre-fix the sidebar was using
// `max_depth = .max` for the `.folder` scope (a copy-paste from `.subfolders`),
// so the histogram for "current folder" actually walked the entire subtree.
// These tests pin the per-folder read at the engine level so the bug can't
// re-emerge from UI code alone.
// ---------------------------------------------------------------------------

test "zest_histogram at depth=1 returns only the folder's direct children" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    // /home/user/docs has notes.txt (text=2) + report.pdf + report_v2.pdf
    // (documents=3). Pre-fix this returned 5 (counted subtree of /home/user).
    const h = zest_histogram(core, "/home/user/docs", 1);
    try std.testing.expectEqual(@as(u32, 0), h.counts[0]); // uncategorized
    try std.testing.expectEqual(@as(u32, 0), h.counts[1]); // images
    try std.testing.expectEqual(@as(u32, 1), h.counts[2]); // text (notes.txt)
    try std.testing.expectEqual(@as(u32, 2), h.counts[3]); // documents (2 PDFs)
    try std.testing.expectEqual(@as(u32, 0), h.counts[7]); // code (app.zig is in /home/user/src)
}

test "zest_histogram at depth=1 on a different folder reports only its own counts" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    // /home/user/src has app.zig (code=7) only. Direct children, not subtree.
    const h = zest_histogram(core, "/home/user/src", 1);
    try std.testing.expectEqual(@as(u32, 1), h.counts[7]);
    try std.testing.expectEqual(@as(u32, 0), h.counts[2]);
    try std.testing.expectEqual(@as(u32, 0), h.counts[3]);
}

test "zest_histogram at .max depth returns the subtree sum" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    // Subtree of /home/user: docs (1 text + 2 docs) + pics (1 image) +
    // src (1 code) = 1 image, 1 text, 2 documents, 1 code.
    const h = zest_histogram(core, "/home/user", std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u32, 1), h.counts[1]); // images (photo.jpg)
    try std.testing.expectEqual(@as(u32, 1), h.counts[2]); // text (notes.txt)
    try std.testing.expectEqual(@as(u32, 2), h.counts[3]); // documents (2 PDFs)
    try std.testing.expectEqual(@as(u32, 1), h.counts[7]); // code (app.zig)
    try std.testing.expectEqual(@as(u32, 0), h.counts[4]); // spreadsheets
    try std.testing.expectEqual(@as(u32, 0), h.counts[5]); // audio
    try std.testing.expectEqual(@as(u32, 0), h.counts[6]); // video
    try std.testing.expectEqual(@as(u32, 0), h.counts[8]); // archives
}

test "zest_histogram returns all zeros for a folder not in the index" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    const h = zest_histogram(core, "/no/such/folder", 1);
    try std.testing.expectEqual(@as(u32, 0), h.counts[0]);
    try std.testing.expectEqual(@as(u32, 0), h.counts[7]);
}

// ---------------------------------------------------------------------------
// Extension breakdown tests. The sidebar's per-category ext list is read out
// of the v3 ext_breakdown column. Tests pin:
//   - per-folder bucket returns just the (cat) exts for the folder's own files
//   - subtree scope merges exts across folders, sorted by count desc
//   - max caps the result length and respects the on-disk sort order
//   - missing folders return 0 rows
// ---------------------------------------------------------------------------

fn readExtName(c: ZestExtCount) []const u8 {
    var i: usize = 0;
    while (i < c.name.len) : (i += 1) {
        if (c.name[i] == 0) break;
    }
    return c.name[0..i];
}

test "zest_ext_breakdown for a folder's own .documents returns the expected ext counts" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    // /home/user/docs has report.pdf + report_v2.pdf in .documents. Two
    // files, one ext. The breakdown should return exactly one row: pdf:2.
    var out: [8]ZestExtCount = undefined;
    for (&out) |*o| o.* = std.mem.zeroes(ZestExtCount);
    const n = zest_ext_breakdown(core, "/home/user/docs", 1, 3, 8, &out);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqualStrings("pdf", readExtName(out[0]));
    try std.testing.expectEqual(@as(u32, 2), out[0].count);
}

test "zest_ext_breakdown with max=1 truncates to the top row" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    // /home/user subtree: cat 3 (documents) has 2 PDFs. With max=1, we get
    // the single top row.
    var out: [8]ZestExtCount = undefined;
    for (&out) |*o| o.* = std.mem.zeroes(ZestExtCount);
    const n = zest_ext_breakdown(core, "/", 999, 3, 1, &out);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqualStrings("pdf", readExtName(out[0]));
    try std.testing.expectEqual(@as(u32, 2), out[0].count);
}

test "zest_ext_breakdown for the whole index returns exts across all categories" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    // Cat 7 (code) at root: exactly one .zig file in /home/user/src.
    var out: [8]ZestExtCount = undefined;
    for (&out) |*o| o.* = std.mem.zeroes(ZestExtCount);
    const n = zest_ext_breakdown(core, "/", 999, 7, 8, &out);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqualStrings("zig", readExtName(out[0]));
    try std.testing.expectEqual(@as(u32, 1), out[0].count);
}

test "zest_ext_breakdown for a missing folder returns zero rows" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    var out: [8]ZestExtCount = undefined;
    for (&out) |*o| o.* = std.mem.zeroes(ZestExtCount);
    const n = zest_ext_breakdown(core, "/no/such/folder", 1, 3, 8, &out);
    try std.testing.expectEqual(@as(u32, 0), n);
}

test "zest_ext_breakdown for an empty category returns zero rows" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    // Cat 5 (audio) has no files anywhere in the fixture.
    var out: [8]ZestExtCount = undefined;
    for (&out) |*o| o.* = std.mem.zeroes(ZestExtCount);
    const n = zest_ext_breakdown(core, "/", 999, 5, 8, &out);
    try std.testing.expectEqual(@as(u32, 0), n);
}

test "zest_ext_breakdown for cat=0 with src dir reports ext=directory" {
    const data = try format.writeIndex(std.testing.allocator, &test_entries);
    defer std.testing.allocator.free(data);
    const core = zest_open(data.ptr, data.len) orelse return error.MalformedIndex;
    defer zest_close(core);

    // The "src" entry (a directory) is in /home/user at cat=0 (uncategorized).
    // The name "src" has no dot, so the writer skips it — ext list is empty.
    var out: [8]ZestExtCount = undefined;
    for (&out) |*o| o.* = std.mem.zeroes(ZestExtCount);
    const n = zest_ext_breakdown(core, "/home/user", 999, 0, 8, &out);
    try std.testing.expectEqual(@as(u32, 0), n);
}
