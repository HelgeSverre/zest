const std = @import("std");
const types = @import("../core/types.zig");
const reader_mod = @import("reader.zig");
const bitmap_mod = @import("bitmap.zig");
const filters_mod = @import("../core/filters.zig");
const subtree_mod = @import("subtree.zig");

pub const SearchOptions = struct {
    query: []const u8,
    filters: []const filters_mod.FilterCriterion = &.{},
    max_results: u32 = 100,
    /// Absolute folder path to scope results to. "/" matches everything indexed.
    scope: []const u8 = "/",
    /// 1 = direct children of `scope` only (a folder listing).
    /// maxInt = the full subtree under `scope` (a recursive filter/search).
    max_depth: u32 = std.math.maxInt(u32),
};

pub const SearchResult = struct {
    index: u32,
    name: []const u8,
    dir_path: []const u8,
    size: u64,
    mtime: i64,
    kind: types.FileKind,
    category: types.FileCategory,
};

pub const SearchCancelled = error{SearchCancelled};

/// Synchronous search (for CLI/tests). Delegates to the cancellable variant with no cancellation.
pub fn search(allocator: std.mem.Allocator, reader: *reader_mod.IndexReader, opts: SearchOptions) ![]SearchResult {
    return searchCancellable(allocator, reader, opts, null, 0);
}

/// Cancellable search for use from background threads.
/// If `generation` is non-null, the search periodically checks whether
/// `generation.load(.acquire) != my_generation` and returns `SearchCancelled` if so.
pub fn searchCancellable(
    allocator: std.mem.Allocator,
    reader: *reader_mod.IndexReader,
    opts: SearchOptions,
    generation: ?*std.atomic.Value(u64),
    my_generation: u64,
) (SearchCancelled || std.mem.Allocator.Error || error{QueryTooLong})![]SearchResult {
    const has_text = opts.query.len > 0;
    const has_filters = opts.filters.len > 0;
    // A non-root scope or a finite depth is a real predicate that must scan and
    // emit (e.g. an empty-text depth-1 query is a folder listing). Only a bare
    // global query with nothing to match short-circuits to empty.
    const scope_is_root = std.mem.eql(u8, opts.scope, "/");
    const has_scope = !scope_is_root or opts.max_depth != std.math.maxInt(u32);

    if (!has_text and !has_filters and !has_scope) return try allocator.alloc(SearchResult, 0);

    // A missing bitmap (init failed to build them) degrades to a no-bitmap
    // scan — never a hard error, and never a lazy rebuild (see
    // `getCategoryBitmaps`: queries may run concurrently with the sidebar).
    var cat_bitmap: ?bitmap_mod.Bitmap = null;

    // Extract category filter for early bitmap filtering
    for (opts.filters) |f| {
        switch (f) {
            .category => |cf| {
                if (!cf.negated and cat_bitmap == null) {
                    if (reader.getCategoryBitmaps()) |bitmaps| {
                        cat_bitmap = bitmaps.get(cf.value);
                    } else |_| {}
                }
            },
            else => {},
        }
    }

    var results: std.ArrayList(SearchResult) = .empty;
    errdefer results.deinit(allocator);
    const num_entries: u32 = @intCast(reader.numEntries());

    if (has_text) {
        // Text search path
        var lower_query_buf: [256]u8 = undefined;
        if (opts.query.len > lower_query_buf.len) return error.QueryTooLong;
        for (opts.query, 0..) |ch, i| {
            lower_query_buf[i] = std.ascii.toLower(ch);
        }
        const lower_query = lower_query_buf[0..opts.query.len];

        const blob_info = reader.getLowerNameBlob() orelse return try allocator.alloc(SearchResult, 0);
        const blob = blob_info.blob;

        if (lower_query.len <= blob.len) {
            const first_char = lower_query[0];
            const last_char = lower_query[lower_query.len - 1];
            const qlen = lower_query.len;

            var pos: usize = 0;
            // Blob positions are scanned in ascending order and names are laid
            // out in entry order, so `findEntryForBlobPos` yields non-decreasing
            // entry indices. A repeated match (a name containing the query more
            // than once) can therefore only collide with the *previous* entry —
            // one compare replaces the old O(results) duplicate scan that made
            // short queries quadratic (4.5s for "i" over a 5.5M-entry index).
            var last_seen_entry: u32 = std.math.maxInt(u32);
            while (pos + qlen <= blob.len and results.items.len < opts.max_results) {
                // Cancellation check every 512 positions (~0.2ms overhead for 100MB blob)
                if (generation) |gen| {
                    if (pos & 0x1FF == 0 and gen.load(.acquire) != my_generation) {
                        return error.SearchCancelled;
                    }
                }

                if (blob[pos] == first_char and blob[pos + qlen - 1] == last_char) {
                    if (std.mem.eql(u8, blob[pos .. pos + qlen], lower_query)) {
                        if (findEntryForBlobPos(reader, @intCast(pos), num_entries)) |entry_idx| {
                            const duplicate = entry_idx == last_seen_entry;
                            last_seen_entry = entry_idx;

                            if (!duplicate) {
                                if (cat_bitmap) |bm| {
                                    if (!bm.contains(entry_idx)) {
                                        pos += 1;
                                        continue;
                                    }
                                }

                                if (buildResult(reader, entry_idx)) |result| {
                                    if (!matchesScope(result.dir_path, opts.scope, opts.max_depth)) {
                                        pos += 1;
                                        continue;
                                    }
                                    if (has_filters and !matchFilters(opts.filters, result)) {
                                        pos += 1;
                                        continue;
                                    }
                                    try results.append(allocator, result);
                                }
                            }
                        }
                    }
                }
                pos += 1;
            }
        }
    } else {
        // Filter-only path: scan entries.
        //
        // A depth-1 folder listing (the every-folder-switch case) would otherwise
        // do `buildResult` + a string `matchesScope` for ALL num_entries — a full
        // ~5.7M-entry index scan (~750ms) regardless of how few files the folder
        // holds, because the result count rarely reaches `max_results`. Instead,
        // resolve the scope to a single dir id once and match the cheap parent-id
        // column (one u32 read per entry), only building results for actual hits.
        const scope_dir_id: ?u32 = if (opts.max_depth == 1 and !scope_is_root)
            (reader.findDirId(stripTrailingSlash(opts.scope)) orelse return try results.toOwnedSlice(allocator))
        else
            null;

        // Subtree scope at unlimited depth: mark descendant dirs once (O(D) over
        // the dedup'd dir table), then test one byte per entry instead of
        // buildResult + string prefix compare for all entries. Finite depths > 1
        // keep the old matchesScope path (depth-limited semantics require the
        // actual string comparison that matchesScope does; the byte table ignores
        // depth limits).
        var subtree_marks: ?[]u8 = null;
        defer if (subtree_marks) |m| allocator.free(m);
        if (opts.max_depth == std.math.maxInt(u32) and !scope_is_root) {
            const dc = reader.dirCount();
            if (dc > 0) {
                const m = try allocator.alloc(u8, dc);
                @memset(m, 0);
                if (subtree_mod.markSubtreeDirs(reader.*, stripTrailingSlash(opts.scope), m)) {
                    subtree_marks = m;
                } else {
                    // Malformed dir table: free the marks buffer and let the
                    // string-compare path (matchesScope) handle scoping.
                    allocator.free(m);
                }
            }
        }

        var idx: u32 = 0;
        while (idx < num_entries and results.items.len < opts.max_results) : (idx += 1) {
            // Cancellation check every 512 entries
            if (generation) |gen| {
                if (idx & 0x1FF == 0 and gen.load(.acquire) != my_generation) {
                    return error.SearchCancelled;
                }
            }

            if (scope_dir_id) |want| {
                if ((reader.getParentId(idx) orelse continue) != want) continue;
            } else if (subtree_marks) |m| {
                const pid = reader.getParentId(idx) orelse continue;
                if (pid >= m.len or m[pid] == 0) continue;
            }
            if (cat_bitmap) |bm| {
                if (!bm.contains(idx)) continue;
            }
            if (buildResult(reader, idx)) |result| {
                // subtree_marks covers the unlimited-depth case; fall back to
                // matchesScope only for the finite-depth > 1 case (rare; keeps
                // depth-limited semantics exact).
                if (subtree_marks == null and !matchesScope(result.dir_path, opts.scope, opts.max_depth)) continue;
                if (!matchFilters(opts.filters, result)) continue;
                try results.append(allocator, result);
            }
        }
    }

    return results.toOwnedSlice(allocator);
}

/// Geometric scope predicate over an entry's `dir_path`.
/// `max_depth == 1` matches only direct children of `scope` (a folder listing).
/// Otherwise matches `scope` and its whole subtree, using a segment-boundary
/// prefix so `/a/b` matches `/a/b/c` but never `/a/bc`. `scope == "/"` (recursive)
/// matches everything indexed.
fn matchesScope(dir_path: []const u8, scope_in: []const u8, max_depth: u32) bool {
    const scope = stripTrailingSlash(scope_in);
    if (max_depth == 1) return std.mem.eql(u8, dir_path, scope);
    if (std.mem.eql(u8, scope, "/")) return true;
    if (std.mem.eql(u8, dir_path, scope)) return true;
    return dir_path.len > scope.len and
        std.mem.startsWith(u8, dir_path, scope) and
        dir_path[scope.len] == '/';
}

/// Drop a single trailing slash (but keep root "/") so a normalized path passed
/// as a scope still matches its children at the segment boundary.
fn stripTrailingSlash(scope: []const u8) []const u8 {
    if (scope.len > 1 and scope[scope.len - 1] == '/') return scope[0 .. scope.len - 1];
    return scope;
}

fn matchFilters(filter_criteria: []const filters_mod.FilterCriterion, result: SearchResult) bool {
    const target = filters_mod.MatchTarget{
        .name = result.name,
        .dir_path = result.dir_path,
        .size = result.size,
        .mtime = result.mtime,
        .kind = result.kind,
        .category = result.category,
    };
    return filters_mod.matchesAll(filter_criteria, target);
}

fn findEntryForBlobPos(reader: *reader_mod.IndexReader, blob_pos: u32, num_entries: u32) ?u32 {
    const names_start: usize = @intCast(reader.header.names_offset);
    const offsets_start = names_start;
    const data = reader.data;

    // The binary search below indexes the offsets (u32×N) and lengths (u16×N)
    // arrays with disk-derived positions. Bound both to the buffer once so a
    // truncated/corrupt index fails to null instead of reading out of bounds.
    const lengths_start = offsets_start + @as(usize, num_entries) * 4;
    if (lengths_start + @as(usize, num_entries) * 2 > data.len) return null;

    var lo: u32 = 0;
    var hi: u32 = num_entries;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const off = std.mem.readInt(u32, data[offsets_start + @as(usize, mid) * 4 ..][0..4], .little);
        if (off <= blob_pos) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    if (lo == 0) return null;
    const entry_idx = lo - 1;

    const entry_offset = std.mem.readInt(u32, data[offsets_start + @as(usize, entry_idx) * 4 ..][0..4], .little);
    const entry_len = std.mem.readInt(u16, data[lengths_start + @as(usize, entry_idx) * 2 ..][0..2], .little);

    if (blob_pos >= entry_offset and blob_pos + 1 <= entry_offset + entry_len) {
        return entry_idx;
    }
    return null;
}

fn buildResult(reader: *reader_mod.IndexReader, idx: u32) ?SearchResult {
    const name = reader.getName(idx) orelse return null;
    const dir_path = reader.getDirPath(idx) orelse return null;
    const meta = reader.getMeta(idx) orelse return null;

    return .{
        .index = idx,
        .name = name,
        .dir_path = dir_path,
        .size = meta.size,
        .mtime = meta.mtime,
        .kind = meta.kind,
        .category = meta.category,
    };
}

// ---------------------------------------------------------------------------
// Row presentation: scope-relative display name and column sorting.
// Pure logic over SearchResult so it can be unit-tested without UI/index.
// ---------------------------------------------------------------------------

/// Columns the file list can sort by. "type" sorts on the category display name.
pub const SortColumn = enum { name, size, mtime, category };

const SortContext = struct { column: SortColumn, ascending: bool, folders_first: bool };

/// Sort `rows` in place by `column`. When `folders_first`, directories are kept
/// above files regardless of column or direction ("keep folders on top");
/// otherwise it's a pure column sort. Ties break by name then dir_path so the
/// order is deterministic across toggles.
pub fn sortResults(rows: []SearchResult, column: SortColumn, ascending: bool, folders_first: bool) void {
    std.mem.sort(SearchResult, rows, SortContext{ .column = column, .ascending = ascending, .folders_first = folders_first }, lessThan);
}

fn lessThan(ctx: SortContext, a: SearchResult, b: SearchResult) bool {
    if (ctx.folders_first) {
        const a_dir = a.kind == .directory;
        const b_dir = b.kind == .directory;
        // Folders always sort above files, independent of column/ascending.
        if (a_dir != b_dir) return a_dir;
    }
    var ord = compareColumn(ctx.column, a, b);
    if (!ctx.ascending) ord = ord.invert();
    if (ord != .eq) return ord == .lt;
    // Stable tiebreak (always ascending) for deterministic ordering.
    const by_name = caseInsensitiveOrder(a.name, b.name);
    if (by_name != .eq) return by_name == .lt;
    return std.mem.order(u8, a.dir_path, b.dir_path) == .lt;
}

fn compareColumn(column: SortColumn, a: SearchResult, b: SearchResult) std.math.Order {
    return switch (column) {
        .name => caseInsensitiveOrder(a.name, b.name),
        .size => std.math.order(a.size, b.size),
        .mtime => std.math.order(a.mtime, b.mtime),
        .category => std.mem.order(u8, a.category.displayName(), b.category.displayName()),
    };
}

fn caseInsensitiveOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca != cb) return std.math.order(ca, cb);
    }
    return std.math.order(a.len, b.len);
}

/// The text shown in the Name column.
/// `show_full_path` → absolute path. Otherwise the path relative to `scope`
/// (just the basename for a direct child; `subdir/name` for a nested match).
/// Caller owns the returned slice.
pub fn displayName(
    allocator: std.mem.Allocator,
    row: SearchResult,
    scope: []const u8,
    show_full_path: bool,
) ![]u8 {
    if (show_full_path) {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ row.dir_path, row.name });
    }
    const rel = relativeDir(row.dir_path, scope);
    if (rel.len == 0) return allocator.dupe(u8, row.name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel, row.name });
}

/// The portion of `dir_path` below `scope` (no leading slash), as a slice into
/// `dir_path`. Empty when `dir_path == scope`. For `scope == "/"` this is the
/// absolute path minus its leading slash.
fn relativeDir(dir_path: []const u8, scope_in: []const u8) []const u8 {
    const scope = stripTrailingSlash(scope_in);
    if (std.mem.eql(u8, scope, "/")) {
        return if (dir_path.len > 0 and dir_path[0] == '/') dir_path[1..] else dir_path;
    }
    if (std.mem.eql(u8, dir_path, scope)) return "";
    if (dir_path.len > scope.len and
        std.mem.startsWith(u8, dir_path, scope) and
        dir_path[scope.len] == '/')
    {
        return dir_path[scope.len + 1 ..];
    }
    // Outside scope (shouldn't happen once the scope predicate has run): show absolute.
    return dir_path;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const format = @import("format.zig");

const test_entries = [_]format.IndexEntry{
    .{ .name = "report.pdf", .dir_path = "/home/user/docs", .size = 2 * 1024 * 1024, .mtime = 1700000000, .kind = .file, .category = .documents },
    .{ .name = "photo.jpg", .dir_path = "/home/user/pics", .size = 500 * 1024, .mtime = 1700100000, .kind = .file, .category = .images },
    .{ .name = "notes.txt", .dir_path = "/home/user/docs", .size = 1024, .mtime = 1700200000, .kind = .file, .category = .text },
    .{ .name = "src", .dir_path = "/home/user", .size = 0, .mtime = 1700300000, .kind = .directory, .category = .uncategorized },
    .{ .name = "report_v2.pdf", .dir_path = "/home/user/docs", .size = 5 * 1024 * 1024, .mtime = 1700400000, .kind = .file, .category = .documents },
    .{ .name = "app.zig", .dir_path = "/home/user/src", .size = 8192, .mtime = 1700500000, .kind = .file, .category = .code },
};

fn buildTestIndex(allocator: std.mem.Allocator) !struct { data: []u8, reader: reader_mod.IndexReader } {
    const data = try format.writeIndex(allocator, &test_entries);
    const reader = try reader_mod.IndexReader.init(allocator, data);
    return .{ .data = data, .reader = reader };
}

test "truncated index degrades gracefully instead of panicking" {
    const allocator = std.testing.allocator;
    const full = try format.writeIndex(allocator, &test_entries);
    defer allocator.free(full);

    // Truncate the index to every possible length and exercise every accessor
    // that reads disk-controlled offsets/lengths. A short or corrupt index must
    // return null/empty, never trigger an out-of-bounds panic.
    var len: usize = 0;
    while (len <= full.len) : (len += 1) {
        var reader = reader_mod.IndexReader.init(allocator, full[0..len]) catch continue;
        defer reader.deinit();

        var idx: u32 = 0;
        while (idx < @as(u32, @intCast(test_entries.len)) + 2) : (idx += 1) {
            _ = reader.getName(idx);
            _ = reader.getDirPath(idx);
            _ = reader.getMeta(idx);
            _ = reader.getParentId(idx);
        }
        _ = reader.findDirId("/home/user/docs");

        var hist: [types.FileCategory.count]u32 = undefined;
        reader.getFolderHistogram(0, &hist);

        var ext_buf: [8]reader_mod.IndexReader.ExtCount = undefined;
        _ = reader.getFolderExtBreakdown(0, 0, &ext_buf);

        if (search(allocator, &reader, .{ .query = "report" })) |r| allocator.free(r) else |_| {}
        if (search(allocator, &reader, .{ .query = "", .scope = "/home/user", .max_depth = 1 })) |r| allocator.free(r) else |_| {}
    }
}

test "search text only" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    const results = try search(allocator, &idx.reader, .{ .query = "report" });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "search filter only ext:pdf" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    var ext_filter = filters_mod.FilterCriterion{ .extension = .{} };
    @memcpy(ext_filter.extension.value[0..3], "pdf");
    ext_filter.extension.len = 3;

    const results = try search(allocator, &idx.reader, .{ .query = "", .filters = &.{ext_filter} });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    // Both should be PDFs
    for (results) |r| {
        try std.testing.expect(std.mem.endsWith(u8, r.name, ".pdf"));
    }
}

test "search filter only kind:folder" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    const results = try search(allocator, &idx.reader, .{
        .query = "",
        .filters = &.{filters_mod.FilterCriterion{ .kind = .{ .value = .directory } }},
    });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("src", results[0].name);
}

test "size filter matches folders by their baked subtree size" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // /home/user/src contains app.zig (8192 bytes), so the folder's baked
    // size is 8192 and both it and the file clear a >5000 threshold.
    const results = try search(allocator, &idx.reader, .{
        .query = "",
        .filters = &.{filters_mod.FilterCriterion{ .size = .{ .op = .gt, .value = 5000 } }},
    });
    defer allocator.free(results);
    var dir_hits: usize = 0;
    var file_hits: usize = 0;
    for (results) |r| {
        if (r.kind == .directory) {
            dir_hits += 1;
            try std.testing.expectEqualStrings("src", r.name);
            try std.testing.expectEqual(@as(u64, 8192), r.size);
        } else file_hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), dir_hits);
    // report.pdf (2MB), photo.jpg (500KB), report_v2.pdf (5MB), app.zig (8192).
    try std.testing.expectEqual(@as(usize, 4), file_hits);
}

test "search filter only size:>1mb" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    const results = try search(allocator, &idx.reader, .{
        .query = "",
        .filters = &.{filters_mod.FilterCriterion{ .size = .{ .op = .gt, .value = 1024 * 1024 } }},
    });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "search filter only category" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    const results = try search(allocator, &idx.reader, .{
        .query = "",
        .filters = &.{filters_mod.FilterCriterion{ .category = .{ .value = .documents } }},
    });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "search text plus filter" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // "report" + ext:pdf -> both report.pdf and report_v2.pdf
    var ext_filter = filters_mod.FilterCriterion{ .extension = .{} };
    @memcpy(ext_filter.extension.value[0..3], "pdf");
    ext_filter.extension.len = 3;

    const results = try search(allocator, &idx.reader, .{
        .query = "report",
        .filters = &.{ext_filter},
    });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "search text plus filter narrows" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // "report" + size:>3mb -> only report_v2.pdf (5MB)
    const results = try search(allocator, &idx.reader, .{
        .query = "report",
        .filters = &.{filters_mod.FilterCriterion{ .size = .{ .op = .gt, .value = 3 * 1024 * 1024 } }},
    });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("report_v2.pdf", results[0].name);
}

test "search multiple filters" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // ext:pdf + size:>3mb -> only report_v2.pdf
    var ext_filter = filters_mod.FilterCriterion{ .extension = .{} };
    @memcpy(ext_filter.extension.value[0..3], "pdf");
    ext_filter.extension.len = 3;

    const results = try search(allocator, &idx.reader, .{
        .query = "",
        .filters = &.{
            ext_filter,
            filters_mod.FilterCriterion{ .size = .{ .op = .gt, .value = 3 * 1024 * 1024 } },
        },
    });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("report_v2.pdf", results[0].name);
}

test "search no results" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    const results = try search(allocator, &idx.reader, .{ .query = "nonexistent" });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "search empty query no filters" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    const results = try search(allocator, &idx.reader, .{ .query = "" });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "search negated filter" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // !kind:directory -> all files (5 of 6)
    const results = try search(allocator, &idx.reader, .{
        .query = "",
        .filters = &.{filters_mod.FilterCriterion{ .kind = .{ .negated = true, .value = .directory } }},
    });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 5), results.len);
}

// ---------------------------------------------------------------------------
// Scope + depth predicate tests
// ---------------------------------------------------------------------------

test "scope depth-1 lists direct children including subdirs" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // Direct children of /home/user: only the "src" directory entry.
    const results = try search(allocator, &idx.reader, .{ .query = "", .scope = "/home/user", .max_depth = 1 });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("src", results[0].name);
}

test "scope depth-1 lists files in a leaf folder" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // Direct children of /home/user/docs: report.pdf, notes.txt, report_v2.pdf
    const results = try search(allocator, &idx.reader, .{ .query = "", .scope = "/home/user/docs", .max_depth = 1 });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 3), results.len);
}

test "scope recursive returns whole subtree" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // Everything under /home/user (all 6 entries are at or below it).
    const results = try search(allocator, &idx.reader, .{ .query = "", .scope = "/home/user", .max_depth = std.math.maxInt(u32) });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 6), results.len);
}

test "scope narrows text search to subtree" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // "app" exists only at /home/user/src, which is NOT under /home/user/docs.
    const results = try search(allocator, &idx.reader, .{ .query = "app", .scope = "/home/user/docs", .max_depth = std.math.maxInt(u32) });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "scope keeps text matches within subtree" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // "report" under /home/user/docs -> report.pdf + report_v2.pdf
    const results = try search(allocator, &idx.reader, .{ .query = "report", .scope = "/home/user/docs", .max_depth = std.math.maxInt(u32) });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "scope prefix respects segment boundary" {
    const allocator = std.testing.allocator;
    const entries = [_]format.IndexEntry{
        .{ .name = "x.txt", .dir_path = "/a/b", .size = 1, .mtime = 1, .kind = .file, .category = .text },
        .{ .name = "y.txt", .dir_path = "/a/bc", .size = 1, .mtime = 1, .kind = .file, .category = .text },
        .{ .name = "z.txt", .dir_path = "/a/b/c", .size = 1, .mtime = 1, .kind = .file, .category = .text },
    };
    const data = try format.writeIndex(allocator, &entries);
    defer allocator.free(data);
    var reader = try reader_mod.IndexReader.init(allocator, data);
    defer reader.deinit();

    // Scope /a/b recursive matches /a/b and /a/b/c but NOT /a/bc.
    const results = try search(allocator, &reader, .{ .query = "", .scope = "/a/b", .max_depth = std.math.maxInt(u32) });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |r| {
        try std.testing.expect(!std.mem.eql(u8, r.dir_path, "/a/bc"));
    }
}

test "scope root with empty query stays empty (no global dump)" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // scope "/" + maxInt depth + empty text + no filters: nothing to scan for.
    const results = try search(allocator, &idx.reader, .{ .query = "", .scope = "/", .max_depth = std.math.maxInt(u32) });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "scope filter combines with scope predicate" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // ext:pdf scoped to /home/user/docs (depth 1) -> both PDFs live there.
    var ext_filter = filters_mod.FilterCriterion{ .extension = .{} };
    @memcpy(ext_filter.extension.value[0..3], "pdf");
    ext_filter.extension.len = 3;

    const results = try search(allocator, &idx.reader, .{
        .query = "",
        .filters = &.{ext_filter},
        .scope = "/home/user/docs",
        .max_depth = 1,
    });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
}

test "text search with scope respects segment boundary" {
    const allocator = std.testing.allocator;
    const entries = [_]format.IndexEntry{
        .{ .name = "report.txt", .dir_path = "/a/b", .size = 1, .mtime = 1, .kind = .file, .category = .text },
        .{ .name = "report.txt", .dir_path = "/a/bc", .size = 1, .mtime = 1, .kind = .file, .category = .text },
        .{ .name = "report.txt", .dir_path = "/a/b/c", .size = 1, .mtime = 1, .kind = .file, .category = .text },
    };
    const data = try format.writeIndex(allocator, &entries);
    defer allocator.free(data);
    var reader = try reader_mod.IndexReader.init(allocator, data);
    defer reader.deinit();

    // "report" under /a/b matches /a/b and /a/b/c but never /a/bc.
    const results = try search(allocator, &reader, .{ .query = "report", .scope = "/a/b", .max_depth = std.math.maxInt(u32) });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |r| {
        try std.testing.expect(!std.mem.eql(u8, r.dir_path, "/a/bc"));
    }
}

test "scope with trailing slash still matches children" {
    const allocator = std.testing.allocator;
    const entries = [_]format.IndexEntry{
        .{ .name = "x.txt", .dir_path = "/a/b", .size = 1, .mtime = 1, .kind = .file, .category = .text },
        .{ .name = "y.txt", .dir_path = "/a/bc", .size = 1, .mtime = 1, .kind = .file, .category = .text },
        .{ .name = "z.txt", .dir_path = "/a/b/c", .size = 1, .mtime = 1, .kind = .file, .category = .text },
    };
    const data = try format.writeIndex(allocator, &entries);
    defer allocator.free(data);
    var reader = try reader_mod.IndexReader.init(allocator, data);
    defer reader.deinit();

    // A normalized "/a/b/" scope must behave like "/a/b".
    const results = try search(allocator, &reader, .{ .query = "", .scope = "/a/b/", .max_depth = std.math.maxInt(u32) });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |r| {
        try std.testing.expect(!std.mem.eql(u8, r.dir_path, "/a/bc"));
    }
}

test "scope deeper than any entry returns empty" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    const results = try search(allocator, &idx.reader, .{ .query = "", .scope = "/nonexistent/deep/path", .max_depth = std.math.maxInt(u32) });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "filter-only subtree query matches descendants but not siblings" {
    const allocator = std.testing.allocator;
    const entries = [_]format.IndexEntry{
        .{ .name = "a.pdf", .dir_path = "/home/u/docs", .size = 1, .mtime = 1, .kind = .file, .category = .documents },
        .{ .name = "b.pdf", .dir_path = "/home/u/docs/sub", .size = 1, .mtime = 1, .kind = .file, .category = .documents },
        .{ .name = "c.pdf", .dir_path = "/home/other", .size = 1, .mtime = 1, .kind = .file, .category = .documents },
        .{ .name = "sub", .dir_path = "/home/u/docs", .size = 0, .mtime = 1, .kind = .directory, .category = .uncategorized },
    };
    const data = try format.writeIndex(allocator, &entries);
    defer allocator.free(data);
    var reader = try reader_mod.IndexReader.init(allocator, data);
    defer reader.deinit();

    // ext:pdf filter + scope "/home/u/docs" + unlimited depth:
    // a.pdf (in /home/u/docs) and b.pdf (in /home/u/docs/sub) must match;
    // c.pdf (in /home/other) must NOT match even though it is a PDF.
    var ext_filter = filters_mod.FilterCriterion{ .extension = .{} };
    @memcpy(ext_filter.extension.value[0..3], "pdf");
    ext_filter.extension.len = 3;

    const results = try search(allocator, &reader, .{
        .query = "",
        .filters = &.{ext_filter},
        .scope = "/home/u/docs",
        .max_depth = std.math.maxInt(u32),
    });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 2), results.len);
    for (results) |r| {
        try std.testing.expect(std.mem.startsWith(u8, r.dir_path, "/home/u/docs"));
    }
}

test "scope root depth-1 selects only root-level entries" {
    const allocator = std.testing.allocator;
    var idx = try buildTestIndex(allocator);
    defer allocator.free(idx.data);
    defer idx.reader.deinit();

    // No entry in the fixture has dir_path == "/", so a root listing is empty.
    const results = try search(allocator, &idx.reader, .{ .query = "", .scope = "/", .max_depth = 1 });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "max_results truncates the result set" {
    const allocator = std.testing.allocator;
    var entries: [10]format.IndexEntry = undefined;
    const names = [_][]const u8{ "report0.pdf", "report1.pdf", "report2.pdf", "report3.pdf", "report4.pdf", "report5.pdf", "report6.pdf", "report7.pdf", "report8.pdf", "report9.pdf" };
    for (&entries, names) |*e, name| {
        e.* = .{ .name = name, .dir_path = "/home/user/docs", .size = 1024, .mtime = 1, .kind = .file, .category = .documents };
    }
    const data = try format.writeIndex(allocator, &entries);
    defer allocator.free(data);
    var reader = try reader_mod.IndexReader.init(allocator, data);
    defer reader.deinit();

    const results = try search(allocator, &reader, .{ .query = "report", .max_results = 3 });
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 3), results.len);
}

// ---------------------------------------------------------------------------
// displayName tests
// ---------------------------------------------------------------------------

test "displayName off shows basename for direct child" {
    const allocator = std.testing.allocator;
    const row = SearchResult{ .index = 0, .name = "report.pdf", .dir_path = "/home/user/docs", .size = 0, .mtime = 0, .kind = .file, .category = .documents };
    const name = try displayName(allocator, row, "/home/user/docs", false);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("report.pdf", name);
}

test "displayName off shows relative path for nested match" {
    const allocator = std.testing.allocator;
    const row = SearchResult{ .index = 0, .name = "app.zig", .dir_path = "/home/user/src", .size = 0, .mtime = 0, .kind = .file, .category = .code };
    const name = try displayName(allocator, row, "/home/user", false);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("src/app.zig", name);
}

test "displayName on shows absolute path" {
    const allocator = std.testing.allocator;
    const row = SearchResult{ .index = 0, .name = "app.zig", .dir_path = "/home/user/src", .size = 0, .mtime = 0, .kind = .file, .category = .code };
    const name = try displayName(allocator, row, "/home/user", true);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("/home/user/src/app.zig", name);
}

test "displayName off with root scope strips leading slash" {
    const allocator = std.testing.allocator;
    const row = SearchResult{ .index = 0, .name = "src", .dir_path = "/home/user", .size = 0, .mtime = 0, .kind = .directory, .category = .uncategorized };
    const name = try displayName(allocator, row, "/", false);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("home/user/src", name);
}

// ---------------------------------------------------------------------------
// Sort comparator tests
// ---------------------------------------------------------------------------

fn sortFixture() [3]SearchResult {
    return .{
        .{ .index = 0, .name = "Beta.txt", .dir_path = "/d", .size = 300, .mtime = 200, .kind = .file, .category = .text },
        .{ .index = 1, .name = "alpha.txt", .dir_path = "/d", .size = 100, .mtime = 300, .kind = .file, .category = .images },
        .{ .index = 2, .name = "gamma.txt", .dir_path = "/d", .size = 200, .mtime = 100, .kind = .file, .category = .documents },
    };
}

test "sort by name ascending is case-insensitive" {
    var rows = sortFixture();
    sortResults(&rows, .name, true, false);
    try std.testing.expectEqualStrings("alpha.txt", rows[0].name);
    try std.testing.expectEqualStrings("Beta.txt", rows[1].name);
    try std.testing.expectEqualStrings("gamma.txt", rows[2].name);
}

test "sort by name descending" {
    var rows = sortFixture();
    sortResults(&rows, .name, false, false);
    try std.testing.expectEqualStrings("gamma.txt", rows[0].name);
    try std.testing.expectEqualStrings("Beta.txt", rows[1].name);
    try std.testing.expectEqualStrings("alpha.txt", rows[2].name);
}

test "sort by size ascending and descending" {
    var rows = sortFixture();
    sortResults(&rows, .size, true, false);
    try std.testing.expectEqual(@as(u64, 100), rows[0].size);
    try std.testing.expectEqual(@as(u64, 200), rows[1].size);
    try std.testing.expectEqual(@as(u64, 300), rows[2].size);
    sortResults(&rows, .size, false, false);
    try std.testing.expectEqual(@as(u64, 300), rows[0].size);
    try std.testing.expectEqual(@as(u64, 200), rows[1].size);
    try std.testing.expectEqual(@as(u64, 100), rows[2].size);
}

test "sort by mtime ascending and descending" {
    var rows = sortFixture();
    sortResults(&rows, .mtime, true, false);
    try std.testing.expectEqual(@as(i64, 100), rows[0].mtime);
    try std.testing.expectEqual(@as(i64, 200), rows[1].mtime);
    try std.testing.expectEqual(@as(i64, 300), rows[2].mtime);
    sortResults(&rows, .mtime, false, false);
    try std.testing.expectEqual(@as(i64, 300), rows[0].mtime);
    try std.testing.expectEqual(@as(i64, 100), rows[2].mtime);
}

test "sort by type uses category display name ascending and descending" {
    var rows = sortFixture();
    // Documents < Images < Text (alphabetical by display name)
    sortResults(&rows, .category, true, false);
    try std.testing.expectEqual(types.FileCategory.documents, rows[0].category);
    try std.testing.expectEqual(types.FileCategory.images, rows[1].category);
    try std.testing.expectEqual(types.FileCategory.text, rows[2].category);
    sortResults(&rows, .category, false, false);
    try std.testing.expectEqual(types.FileCategory.text, rows[0].category);
    try std.testing.expectEqual(types.FileCategory.images, rows[1].category);
    try std.testing.expectEqual(types.FileCategory.documents, rows[2].category);
}

test "sort tiebreak is deterministic by name then dir_path" {
    // Equal size keys: tie broken by name (case-insensitive) ascending.
    var by_name = [_]SearchResult{
        .{ .index = 0, .name = "b.txt", .dir_path = "/d", .size = 100, .mtime = 0, .kind = .file, .category = .text },
        .{ .index = 1, .name = "a.txt", .dir_path = "/d", .size = 100, .mtime = 0, .kind = .file, .category = .text },
    };
    sortResults(&by_name, .size, true, false);
    try std.testing.expectEqualStrings("a.txt", by_name[0].name);
    try std.testing.expectEqualStrings("b.txt", by_name[1].name);

    // Equal size and name: tie broken by dir_path ascending.
    var by_dir = [_]SearchResult{
        .{ .index = 0, .name = "f.txt", .dir_path = "/z", .size = 100, .mtime = 0, .kind = .file, .category = .text },
        .{ .index = 1, .name = "f.txt", .dir_path = "/a", .size = 100, .mtime = 0, .kind = .file, .category = .text },
    };
    sortResults(&by_dir, .size, true, false);
    try std.testing.expectEqualStrings("/a", by_dir[0].dir_path);
    try std.testing.expectEqualStrings("/z", by_dir[1].dir_path);
}

test "sort with folders_first keeps directories above files" {
    var rows = [_]SearchResult{
        .{ .index = 0, .name = "zeta.txt", .dir_path = "/d", .size = 0, .mtime = 0, .kind = .file, .category = .text },
        .{ .index = 1, .name = "alpha", .dir_path = "/d", .size = 0, .mtime = 0, .kind = .directory, .category = .uncategorized },
        .{ .index = 2, .name = "beta.txt", .dir_path = "/d", .size = 0, .mtime = 0, .kind = .file, .category = .text },
        .{ .index = 3, .name = "omega", .dir_path = "/d", .size = 0, .mtime = 0, .kind = .directory, .category = .uncategorized },
    };
    // Name ascending, folders first: both dirs before both files.
    sortResults(&rows, .name, true, true);
    try std.testing.expect(rows[0].kind == .directory);
    try std.testing.expect(rows[1].kind == .directory);
    try std.testing.expectEqualStrings("alpha", rows[0].name);
    try std.testing.expectEqualStrings("omega", rows[1].name);
    try std.testing.expect(rows[2].kind == .file);
    try std.testing.expect(rows[3].kind == .file);

    // Name descending, folders first: folders still on top (not flipped below).
    sortResults(&rows, .name, false, true);
    try std.testing.expect(rows[0].kind == .directory);
    try std.testing.expect(rows[1].kind == .directory);
    try std.testing.expectEqualStrings("omega", rows[0].name);
    try std.testing.expectEqualStrings("alpha", rows[1].name);

    // folders_first = false: pure column sort interleaves dirs and files.
    sortResults(&rows, .name, true, false);
    try std.testing.expectEqualStrings("alpha", rows[0].name);
    try std.testing.expectEqualStrings("beta.txt", rows[1].name);
    try std.testing.expectEqualStrings("omega", rows[2].name);
    try std.testing.expectEqualStrings("zeta.txt", rows[3].name);
}

test "displayName on shows absolute path for direct child" {
    const allocator = std.testing.allocator;
    const row = SearchResult{ .index = 0, .name = "report.pdf", .dir_path = "/home/user/docs", .size = 0, .mtime = 0, .kind = .file, .category = .documents };
    const name = try displayName(allocator, row, "/home/user/docs", true);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("/home/user/docs/report.pdf", name);
}
