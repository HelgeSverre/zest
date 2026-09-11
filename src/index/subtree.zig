const std = @import("std");
const types = @import("../core/types.zig");
const reader_mod = @import("reader.zig");
const format = @import("format.zig");
const paths = @import("../core/paths.zig");

/// Sum per-category counts across the subtree rooted at `scope_path`.
/// Walks the (deduplicated) dir table to find descendants; O(D) in the
/// number of unique directories. For `.everywhere` (`scope = "/"`), this
/// is the global histogram. For `.subfolders`, it's the subtree of the
/// current folder. Direct children (`.folder`, `max_depth == 1`) should
/// use `reader.getFolderHistogram` instead — O(1).
pub fn computeHistogram(reader: reader_mod.IndexReader, scope_path: []const u8, out: *[types.FileCategory.count]u32) void {
    @memset(out, 0);
    const table = reader.dirTable() orelse return;

    var counts: [types.FileCategory.count]u32 = .{0} ** types.FileCategory.count;
    var d: u32 = 0;
    while (d < table.count) : (d += 1) {
        const path = table.path(d) orelse continue;
        if (!paths.isPathUnder(path, scope_path)) continue;

        var folder: [types.FileCategory.count]u32 = undefined;
        reader.getFolderHistogram(d, &folder);
        for (0..types.FileCategory.count) |i| counts[i] += folder[i];
    }
    @memcpy(out, &counts);
}

/// Merge per-bucket ext counts across the subtree rooted at `scope_path`
/// (deduplicated by ext name; summed across folders). Sums are aggregated
/// in a per-call temp hash map, then sorted by count desc and truncated to
/// `out.len`. Returns the number of rows written. O(D) forward walk of
/// the ext_breakdown column, where D is the number of unique directories
/// in the index (all of them for `.everywhere`, a subset for `.subfolders`).
///
/// Implementation note: the column is laid out `[dir_id][cat]`, so a
/// single forward pass reads each (dir, cat) bucket header in order and
/// merges the (matching cat) buckets that fall inside the subtree. This
/// is O(D × cats) bytes of reads — for a 100K-dir index, ~9 MB, well
/// under 10ms on a cold mmap.
pub fn computeExtBreakdown(reader: reader_mod.IndexReader, scope_path: []const u8, cat: u8, out: []reader_mod.IndexReader.ExtCount, allocator: std.mem.Allocator) usize {
    if (out.len == 0) return 0;
    if (cat >= types.FileCategory.count) return 0;

    const header = reader.header;
    const data = reader.data;
    const num_dirs = reader.dirCount();
    if (num_dirs == 0) return 0;

    const col_start: usize = @intCast(header.ext_breakdown_offset);
    if (col_start >= data.len) return 0;

    // Build a "is in subtree" bitmap keyed by dir_id. For the root
    // scope, all dirs are in; for subfolders, we walk the dir table once
    // to mark the descendants. The bitmap is a `[]u8` of size `num_dirs`,
    // where byte d is 1 if d is in the subtree. This lets the inner
    // merge loop test membership in O(1) with no allocations.
    const in_subtree = allocator.alloc(u8, num_dirs) catch return 0;
    defer allocator.free(in_subtree);
    @memset(in_subtree, 0);
    if (!markSubtreeDirs(reader, scope_path, in_subtree)) return 0;

    // Single forward walk of the column. For each (dir_id, cat) bucket,
    // check if the bucket's cat matches AND dir_id is in the subtree. If
    // both, merge. Always advance past the bucket.
    //
    // Key by the ext-name bytes (a slice into `data`, which outlives this
    // call) so identical ext names in different dirs hit the same map entry.
    // The old KeyOff approach keyed on the prospective append offset into a
    // scratch buffer, which strictly increased every iteration, so
    // `found_existing` was never true and duplicates never merged.
    var merge = std.StringHashMap(u32).init(allocator);
    defer merge.deinit();

    var pos: usize = col_start;
    var d: u32 = 0;
    while (d < num_dirs) : (d += 1) {
        var c: u8 = 0;
        while (c < types.FileCategory.count) : (c += 1) {
            if (pos + 2 > data.len) return 0;
            const num_exts = std.mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;
            const ext_end = reader.bucketEnd(pos, num_exts);
            if (ext_end == 0) return 0;

            if (c == cat and in_subtree[d] != 0) {
                var p: usize = pos;
                while (p < ext_end) {
                    const len = data[p];
                    p += 1;
                    // Defensive: skip overflow ext names (see readBucketInto).
                    if (len > reader_mod.IndexReader.MAX_EXT_NAME_LEN) {
                        p += len + 4;
                        continue;
                    }
                    const name = data[p..@intCast(p + len)];
                    p += len;
                    const count = std.mem.readInt(u32, data[p..][0..4], .little);
                    p += 4;

                    const gop = merge.getOrPut(name) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += count;
                }
            }
            pos = ext_end;
        }
    }

    // Materialize the merged map into fixed-size ExtCount rows. The
    // caller's `out` slice is what we copy into, so the rows are
    // self-owned by the time we return.
    var scratch = std.ArrayList(reader_mod.IndexReader.ExtCount).empty;
    defer scratch.deinit(allocator);
    scratch.ensureTotalCapacity(allocator, merge.count()) catch return 0;
    var it = merge.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const len: u8 = @intCast(name.len);
        var row = reader_mod.IndexReader.ExtCount{
            .name = undefined,
            .name_len = len,
            .count = entry.value_ptr.*,
        };
        @memcpy(row.name[0..len], name);
        scratch.append(allocator, row) catch continue;
    }

    const lessExt = struct {
        fn f(_: void, a: reader_mod.IndexReader.ExtCount, b: reader_mod.IndexReader.ExtCount) bool {
            // Count desc, name asc on ties — the hash map iterates in
            // unspecified order, so without the tie-break equal-count rows
            // would shuffle between sidebar refreshes.
            if (a.count != b.count) return a.count > b.count;
            return std.mem.order(u8, a.name[0..a.name_len], b.name[0..b.name_len]) == .lt;
        }
    }.f;
    std.mem.sort(reader_mod.IndexReader.ExtCount, scratch.items, {}, lessExt);

    const n = @min(scratch.items.len, out.len);
    for (0..n) |i| out[i] = scratch.items[i];
    return n;
}

/// Fill `marks[dir_id] = 1` for `scope_path`'s dir and every descendant dir.
/// `marks.len` must equal the dir-table count (reader.dirCount()). O(D) over
/// the dedup'd dir table — built once per query so entry filtering is one byte
/// test instead of a string prefix compare per entry.
/// Returns false if the dir table is malformed (caller should fall back to the
/// string-compare path and free the marks buffer).
/// Uses the same boundary-safe predicate as paths.isPathUnder.
pub fn markSubtreeDirs(reader: reader_mod.IndexReader, scope_path: []const u8, marks: []u8) bool {
    const table = reader.dirTable() orelse return false;
    var d: u32 = 0;
    while (d < marks.len and d < table.count) : (d += 1) {
        const path = table.path(d) orelse continue;
        if (paths.isPathUnder(path, scope_path)) marks[d] = 1;
    }
    return true;
}

test "subtree ext breakdown merges the same ext across directories" {
    const entries = [_]format.IndexEntry{
        .{ .name = "a.pdf", .dir_path = "/home/u/x", .size = 1, .mtime = 1, .kind = .file, .category = .documents },
        .{ .name = "b.pdf", .dir_path = "/home/u/y", .size = 1, .mtime = 1, .kind = .file, .category = .documents },
    };
    const data = try format.writeIndex(std.testing.allocator, &entries);
    defer std.testing.allocator.free(data);
    var reader = try reader_mod.IndexReader.init(std.testing.allocator, data);
    defer reader.deinit();

    var out: [8]reader_mod.IndexReader.ExtCount = undefined;
    // cat=3 is .documents
    const n = computeExtBreakdown(reader, "/home/u", 3, out[0..], std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), n); // ONE merged "pdf" row
    try std.testing.expectEqual(@as(u32, 2), out[0].count); // …with count 2
    try std.testing.expectEqualStrings("pdf", out[0].name[0..out[0].name_len]);
}
