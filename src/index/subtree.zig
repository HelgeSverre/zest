const std = @import("std");
const types = @import("../core/types.zig");
const reader_mod = @import("reader.zig");
const format = @import("format.zig");

/// Hash context for the temporary merge map in `computeExtBreakdown`. The
/// key is `(off, len)` into the ext storage buffer — we hash both so distinct
/// keys collide only when both fields match, and the equality check is a
/// pointer+length compare (no per-call memcmp on long strings).
const KeyOff = struct {
    off: u32,
    len: u8,
};

const KeyOffContext = struct {
    pub fn hash(_: KeyOffContext, ko: KeyOff) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&ko.off));
        h.update(&[_]u8{ko.len});
        return h.final();
    }
    pub fn eql(_: KeyOffContext, a: KeyOff, b: KeyOff) bool {
        return a.off == b.off and a.len == b.len;
    }
};

/// Sum per-category counts across the subtree rooted at `scope_path`.
/// Walks the (deduplicated) dir table to find descendants; O(D) in the
/// number of unique directories. For `.everywhere` (`scope = "/"`), this
/// is the global histogram. For `.subfolders`, it's the subtree of the
/// current folder. Direct children (`.folder`, `max_depth == 1`) should
/// use `reader.getFolderHistogram` instead — O(1).
pub fn computeHistogram(reader: reader_mod.IndexReader, scope_path: []const u8, out: *[types.FileCategory.count]u32) void {
    @memset(out, 0);

    const header = reader.header;
    const data = reader.data;
    const num: usize = @intCast(header.num_entries);
    const parent_ids_start: usize = @intCast(header.paths_offset);
    const dir_count_offset = parent_ids_start + num * 4;
    if (dir_count_offset + 4 > data.len) return;
    const dir_count = std.mem.readInt(u32, data[dir_count_offset..][0..4], .little);
    const dir_offsets_start = dir_count_offset + 4;
    const dir_blob_len_pos = dir_offsets_start + dir_count * 4;
    if (dir_blob_len_pos + 4 > data.len) return;
    const dir_blob_len = std.mem.readInt(u32, data[dir_blob_len_pos..][0..4], .little);
    const dir_blob_start = dir_blob_len_pos + 4;
    if (dir_blob_start + dir_blob_len > data.len) return;

    const is_root_scope = scope_path.len == 1 and scope_path[0] == '/';

    var counts: [types.FileCategory.count]u32 = .{0} ** types.FileCategory.count;
    var d: u32 = 0;
    while (d < dir_count) : (d += 1) {
        const off = std.mem.readInt(u32, data[dir_offsets_start + d * 4 ..][0..4], .little);
        const next: u32 = if (d + 1 < dir_count)
            std.mem.readInt(u32, data[dir_offsets_start + (d + 1) * 4 ..][0..4], .little)
        else
            dir_blob_len;
        if (next < off or next > dir_blob_len) continue;
        const path = data[dir_blob_start + off .. dir_blob_start + next];

        const is_descendant = blk: {
            if (is_root_scope) break :blk true;
            if (path.len < scope_path.len) break :blk false;
            if (!std.mem.eql(u8, path[0..scope_path.len], scope_path)) break :blk false;
            if (path.len == scope_path.len) break :blk true;
            if (path[scope_path.len] == '/') break :blk true;
            break :blk false;
        };
        if (!is_descendant) continue;

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
    const num_dirs = dirCount(header, data) orelse return 0;
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
    if (!markSubtreeDirsRaw(header, data, scope_path, in_subtree)) return 0;

    // Single forward walk of the column. For each (dir_id, cat) bucket,
    // check if the bucket's cat matches AND dir_id is in the subtree. If
    // both, merge. Always advance past the bucket.
    var ext_storage = std.ArrayList(u8).empty;
    defer ext_storage.deinit(allocator);

    var merge = std.HashMap(KeyOff, u32, KeyOffContext, std.hash_map.default_max_load_percentage).init(allocator);
    defer merge.deinit();

    var pos: usize = col_start;
    var d: u32 = 0;
    while (d < num_dirs) : (d += 1) {
        var c: u8 = 0;
        while (c < types.FileCategory.count) : (c += 1) {
            if (pos + 2 > data.len) return 0;
            const num_exts = std.mem.readInt(u16, data[pos..][0..2], .little);
            pos += 2;
            if (!skipExts(data, pos, num_exts)) return 0;
            const ext_end = bucketEnd(data, pos, num_exts);
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

                    const key = KeyOff{
                        .off = @intCast(ext_storage.items.len),
                        .len = @intCast(len),
                    };
                    const gop = merge.getOrPut(key) catch continue;
                    if (!gop.found_existing) {
                        ext_storage.appendSlice(allocator, name) catch continue;
                        gop.value_ptr.* = 0;
                    }
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
        const ko = entry.key_ptr.*;
        const n: usize = @intCast(ko.off + ko.len);
        var row = reader_mod.IndexReader.ExtCount{
            .name = undefined,
            .name_len = @intCast(ko.len),
            .count = entry.value_ptr.*,
        };
        @memcpy(row.name[0..ko.len], ext_storage.items[ko.off..n]);
        scratch.append(allocator, row) catch continue;
    }

    const lessExt = struct {
        fn f(_: void, a: reader_mod.IndexReader.ExtCount, b: reader_mod.IndexReader.ExtCount) bool {
            return a.count > b.count;
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
/// Uses the same boundary-safe predicate as config.isPathUnder.
pub fn markSubtreeDirs(reader: reader_mod.IndexReader, scope_path: []const u8, marks: []u8) void {
    _ = markSubtreeDirsRaw(reader.header, reader.data, scope_path, marks);
}

/// Mark `in_subtree[d] = 1` for every dir id that falls under
/// `scope_path` (or every dir if `scope_path == "/"`). Returns false
/// if the dir table is malformed.
fn markSubtreeDirsRaw(header: format.Header, data: []const u8, scope_path: []const u8, in_subtree: []u8) bool {
    const num = in_subtree.len;
    const parent_ids_start: usize = @intCast(header.paths_offset);
    const dir_count_offset = parent_ids_start + @as(usize, @intCast(header.num_entries)) * 4;
    if (dir_count_offset + 4 > data.len) return false;
    const dir_count = std.mem.readInt(u32, data[dir_count_offset..][0..4], .little);
    const dir_offsets_start = dir_count_offset + 4;
    const dir_blob_len_pos = dir_offsets_start + dir_count * 4;
    if (dir_blob_len_pos + 4 > data.len) return false;
    const dir_blob_len = std.mem.readInt(u32, data[dir_blob_len_pos..][0..4], .little);
    const dir_blob_start = dir_blob_len_pos + 4;
    if (dir_blob_start + dir_blob_len > data.len) return false;

    const is_root_scope = scope_path.len == 1 and scope_path[0] == '/';
    var d: u32 = 0;
    while (d < num and d < dir_count) : (d += 1) {
        if (is_root_scope) {
            in_subtree[d] = 1;
            continue;
        }
        const off = std.mem.readInt(u32, data[dir_offsets_start + d * 4 ..][0..4], .little);
        const next: u32 = if (d + 1 < dir_count)
            std.mem.readInt(u32, data[dir_offsets_start + (d + 1) * 4 ..][0..4], .little)
        else
            dir_blob_len;
        if (next < off or next > dir_blob_len) continue;
        const path = data[dir_blob_start + off .. dir_blob_start + next];

        const is_descendant = blk: {
            if (path.len < scope_path.len) break :blk false;
            if (!std.mem.eql(u8, path[0..scope_path.len], scope_path)) break :blk false;
            if (path.len == scope_path.len) break :blk true;
            if (path[scope_path.len] == '/') break :blk true;
            break :blk false;
        };
        if (is_descendant) in_subtree[d] = 1;
    }
    return true;
}

/// Number of directories in the dir table. Cached inline.
fn dirCount(header: format.Header, data: []const u8) ?u32 {
    const num: usize = @intCast(header.num_entries);
    const parent_ids_start: usize = @intCast(header.paths_offset);
    const dir_count_offset = parent_ids_start + num * 4;
    if (dir_count_offset + 4 > data.len) return null;
    return std.mem.readInt(u32, data[dir_count_offset..][0..4], .little);
}

/// Bounds check: would advancing past `num_exts` ext entries starting at
/// `ext_start` fall inside `data`? Cheap, no allocations.
fn skipExts(data: []const u8, ext_start: usize, num_exts: u16) bool {
    var p = ext_start;
    var i: u16 = 0;
    while (i < num_exts) : (i += 1) {
        if (p + 1 > data.len) return false;
        const len = data[p];
        p += 1 + len + 4;
        if (p > data.len) return false;
    }
    return true;
}

/// Compute the byte position just past `num_exts` ext entries starting at
/// `ext_start`. Returns 0 if the column is truncated.
fn bucketEnd(data: []const u8, ext_start: usize, num_exts: u16) usize {
    var p = ext_start;
    var i: u16 = 0;
    while (i < num_exts) : (i += 1) {
        if (p + 1 > data.len) return 0;
        const len = data[p];
        p += 1;
        p += len;
        p += 4; // u32 count
        if (p > data.len) return 0;
    }
    return p;
}
