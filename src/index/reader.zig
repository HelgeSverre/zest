const std = @import("std");
const types = @import("../core/types.zig");
const format = @import("format.zig");
const bitmap_mod = @import("bitmap.zig");
const runtime = @import("../core/runtime.zig");

/// Hash context for the temporary merge map in `getSubtreeExtBreakdown`. The
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

/// Read-only access to a serialized index (from memory buffer or mmap).
pub const IndexReader = struct {
    data: []const u8,
    header: format.Header,
    allocator: std.mem.Allocator,
    category_bitmaps: ?std.AutoHashMap(types.FileCategory, bitmap_mod.Bitmap) = null,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) !IndexReader {
        if (data.len < format.HEADER_SIZE) return error.IndexTooSmall;
        var header_reader = std.Io.Reader.fixed(data[0..format.HEADER_SIZE]);
        const header = format.Header.deserialize(&header_reader) catch return error.InvalidIndex;

        var reader = IndexReader{
            .data = data,
            .header = header,
            .allocator = allocator,
        };

        // Eagerly initialize category bitmaps for thread safety —
        // after init, the reader is safe to use from any thread.
        reader.category_bitmaps = bitmap_mod.readCategoryBitmaps(
            allocator,
            data,
            @intCast(header.bitmap_offset),
        ) catch null;

        return reader;
    }

    pub fn deinit(self: *IndexReader) void {
        if (self.category_bitmaps) |*bitmaps| {
            var iter = bitmaps.iterator();
            while (iter.next()) |entry| {
                var bm = entry.value_ptr.*;
                bm.deinit();
            }
            bitmaps.deinit();
        }
    }

    pub fn numEntries(self: IndexReader) u64 {
        return self.header.num_entries;
    }

    pub fn getName(self: IndexReader, idx: u32) ?[]const u8 {
        const num: usize = @intCast(self.header.num_entries);
        if (idx >= num) return null;

        const names_start: usize = @intCast(self.header.names_offset);
        const offsets_start = names_start;
        const lengths_start = offsets_start + num * 4;
        const blob_len_start = lengths_start + num * 2;

        if (blob_len_start + 4 > self.data.len) return null;
        const blob_len = std.mem.readInt(u32, self.data[blob_len_start..][0..4], .little);
        const blob_start = blob_len_start + 4;

        const name_offset = std.mem.readInt(u32, self.data[offsets_start + idx * 4 ..][0..4], .little);
        const name_length = std.mem.readInt(u16, self.data[lengths_start + idx * 2 ..][0..2], .little);

        const start = blob_start + name_offset;
        const end = start + name_length;
        if (end > blob_start + blob_len) return null;

        return self.data[start..end];
    }

    pub fn getLowerNameBlob(self: IndexReader) ?struct { blob: []const u8, offsets_start: usize, lengths_start: usize } {
        const num: usize = @intCast(self.header.num_entries);
        const names_start: usize = @intCast(self.header.names_offset);
        const offsets_start = names_start;
        const lengths_start = offsets_start + num * 4;
        const blob_len_start = lengths_start + num * 2;

        if (blob_len_start + 4 > self.data.len) return null;
        const orig_blob_len = std.mem.readInt(u32, self.data[blob_len_start..][0..4], .little);
        const lower_len_start = blob_len_start + 4 + orig_blob_len;

        if (lower_len_start + 4 > self.data.len) return null;
        const lower_blob_len = std.mem.readInt(u32, self.data[lower_len_start..][0..4], .little);
        const lower_blob_start = lower_len_start + 4;

        if (lower_blob_start + lower_blob_len > self.data.len) return null;
        return .{
            .blob = self.data[lower_blob_start .. lower_blob_start + lower_blob_len],
            .offsets_start = offsets_start,
            .lengths_start = lengths_start,
        };
    }

    pub fn getDirPath(self: IndexReader, idx: u32) ?[]const u8 {
        const num: usize = @intCast(self.header.num_entries);
        if (idx >= num) return null;

        const paths_start: usize = @intCast(self.header.paths_offset);
        const parent_ids_start = paths_start;

        const pid_offset = parent_ids_start + idx * 4;
        if (pid_offset + 4 > self.data.len) return null;
        const parent_id = std.mem.readInt(u32, self.data[pid_offset..][0..4], .little);

        const dir_count_offset = parent_ids_start + num * 4;
        if (dir_count_offset + 4 > self.data.len) return null;
        const dir_count = std.mem.readInt(u32, self.data[dir_count_offset..][0..4], .little);
        if (parent_id >= dir_count) return null;

        const dir_offsets_start = dir_count_offset + 4;
        const dir_off_pos = dir_offsets_start + parent_id * 4;
        if (dir_off_pos + 4 > self.data.len) return null;
        const dir_offset = std.mem.readInt(u32, self.data[dir_off_pos..][0..4], .little);

        const dir_blob_len_pos = dir_offsets_start + dir_count * 4;
        if (dir_blob_len_pos + 4 > self.data.len) return null;
        const dir_blob_len = std.mem.readInt(u32, self.data[dir_blob_len_pos..][0..4], .little);
        const dir_blob_start = dir_blob_len_pos + 4;

        const next_offset = if (parent_id + 1 < dir_count)
            std.mem.readInt(u32, self.data[dir_offsets_start + (parent_id + 1) * 4 ..][0..4], .little)
        else
            dir_blob_len;

        const start = dir_blob_start + dir_offset;
        const end = dir_blob_start + next_offset;
        if (end > self.data.len) return null;

        return self.data[start..end];
    }

    /// Read the deduplicated directory id for entry `idx` (cheap: one u32 read).
    /// Entries sharing a directory share an id, so a depth-1 folder listing can
    /// match on this instead of building + comparing each entry's dir_path.
    pub fn getParentId(self: IndexReader, idx: u32) ?u32 {
        const num: usize = @intCast(self.header.num_entries);
        if (idx >= num) return null;
        const parent_ids_start: usize = @intCast(self.header.paths_offset);
        const pid_offset = parent_ids_start + idx * 4;
        if (pid_offset + 4 > self.data.len) return null;
        return std.mem.readInt(u32, self.data[pid_offset..][0..4], .little);
    }

    /// Resolve an absolute directory path to its dir-table id, or null if the
    /// directory is not present in the index. Linear scan of the (deduplicated)
    /// directory table — far cheaper than scanning all entries.
    pub fn findDirId(self: IndexReader, path: []const u8) ?u32 {
        const num: usize = @intCast(self.header.num_entries);
        const parent_ids_start: usize = @intCast(self.header.paths_offset);
        const dir_count_offset = parent_ids_start + num * 4;
        if (dir_count_offset + 4 > self.data.len) return null;
        const dir_count = std.mem.readInt(u32, self.data[dir_count_offset..][0..4], .little);

        const dir_offsets_start = dir_count_offset + 4;
        const dir_blob_len_pos = dir_offsets_start + dir_count * 4;
        if (dir_blob_len_pos + 4 > self.data.len) return null;
        const dir_blob_len = std.mem.readInt(u32, self.data[dir_blob_len_pos..][0..4], .little);
        const dir_blob_start = dir_blob_len_pos + 4;
        if (dir_blob_start + dir_blob_len > self.data.len) return null;

        var d: u32 = 0;
        while (d < dir_count) : (d += 1) {
            const off = std.mem.readInt(u32, self.data[dir_offsets_start + d * 4 ..][0..4], .little);
            const next = if (d + 1 < dir_count)
                std.mem.readInt(u32, self.data[dir_offsets_start + (d + 1) * 4 ..][0..4], .little)
            else
                dir_blob_len;
            if (next < off or next > dir_blob_len) continue;
            if (std.mem.eql(u8, self.data[dir_blob_start + off .. dir_blob_start + next], path)) return d;
        }
        return null;
    }

    pub fn getMeta(self: IndexReader, idx: u32) ?struct { size: u64, mtime: i64, kind: types.FileKind, category: types.FileCategory } {
        const num: usize = @intCast(self.header.num_entries);
        if (idx >= num) return null;

        const meta_start: usize = @intCast(self.header.meta_offset);
        const sizes_start = meta_start;
        const mtimes_start = sizes_start + num * 8;
        const kinds_start = mtimes_start + num * 8;
        const cats_start = kinds_start + num;

        if (cats_start + num > self.data.len) return null;

        const size = std.mem.readInt(u64, self.data[sizes_start + idx * 8 ..][0..8], .little);
        const mtime = std.mem.readInt(i64, self.data[mtimes_start + idx * 8 ..][0..8], .little);
        const kind: types.FileKind = @enumFromInt(self.data[kinds_start + idx]);
        const category: types.FileCategory = @enumFromInt(self.data[cats_start + idx]);

        return .{ .size = size, .mtime = mtime, .kind = kind, .category = category };
    }

    pub fn getCategoryBitmaps(self: *IndexReader) !*std.AutoHashMap(types.FileCategory, bitmap_mod.Bitmap) {
        if (self.category_bitmaps == null) {
            self.category_bitmaps = try bitmap_mod.readCategoryBitmaps(
                self.allocator,
                self.data,
                @intCast(self.header.bitmap_offset),
            );
        }
        return &self.category_bitmaps.?;
    }

    /// O(1) read of 9 per-category counts for `dir_id`. Writes zeros to `out`
    /// if the dir_id is out of range (defensive — caller should resolve via
    /// `findDirId` first, but a malformed input shouldn't crash the sidebar).
    pub fn getFolderHistogram(self: IndexReader, dir_id: u32, out: *[types.FileCategory.count]u32) void {
        const hist_start: usize = @intCast(self.header.histogram_offset);
        const row_size: usize = types.FileCategory.count * @sizeOf(u32);
        const dir_offset = hist_start + @as(usize, dir_id) * row_size;
        if (dir_offset + row_size > self.data.len) {
            @memset(out, 0);
            return;
        }
        for (0..types.FileCategory.count) |i| {
            out[i] = std.mem.readInt(
                u32,
                self.data[dir_offset + i * @sizeOf(u32) ..][0..@sizeOf(u32)],
                .little,
            );
        }
    }

    /// Sum per-category counts across the subtree rooted at `scope_path`.
    /// Walks the (deduplicated) dir table to find descendants; O(D) in the
    /// number of unique directories. For `.everywhere` (`scope = "/"`), this
    /// is the global histogram. For `.subfolders`, it's the subtree of the
    /// current folder. Direct children (`.folder`, `max_depth == 1`) should
    /// use `getFolderHistogram` instead — O(1).
    pub fn getSubtreeHistogram(
        self: IndexReader,
        scope_path: []const u8,
        out: *[types.FileCategory.count]u32,
    ) void {
        @memset(out, 0);

        const num: usize = @intCast(self.header.num_entries);
        const parent_ids_start: usize = @intCast(self.header.paths_offset);
        const dir_count_offset = parent_ids_start + num * 4;
        if (dir_count_offset + 4 > self.data.len) return;
        const dir_count = std.mem.readInt(u32, self.data[dir_count_offset..][0..4], .little);
        const dir_offsets_start = dir_count_offset + 4;
        const dir_blob_len_pos = dir_offsets_start + dir_count * 4;
        if (dir_blob_len_pos + 4 > self.data.len) return;
        const dir_blob_len = std.mem.readInt(u32, self.data[dir_blob_len_pos..][0..4], .little);
        const dir_blob_start = dir_blob_len_pos + 4;
        if (dir_blob_start + dir_blob_len > self.data.len) return;

        const is_root_scope = scope_path.len == 1 and scope_path[0] == '/';

        var counts: [types.FileCategory.count]u32 = .{0} ** types.FileCategory.count;
        var d: u32 = 0;
        while (d < dir_count) : (d += 1) {
            const off = std.mem.readInt(u32, self.data[dir_offsets_start + d * 4 ..][0..4], .little);
            const next: u32 = if (d + 1 < dir_count)
                std.mem.readInt(u32, self.data[dir_offsets_start + (d + 1) * 4 ..][0..4], .little)
            else
                dir_blob_len;
            if (next < off or next > dir_blob_len) continue;
            const path = self.data[dir_blob_start + off .. dir_blob_start + next];

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
            self.getFolderHistogram(d, &folder);
            for (0..types.FileCategory.count) |i| counts[i] += folder[i];
        }
        @memcpy(out, &counts);
    }

    /// Single (ext, count) row. `name` is a fixed-size buffer (max 16 bytes
    /// in the on-disk format, capped to 15 here so the struct is NUL-safe
    /// for the C ABI's `ZestExtCount.name[16]`). `name_len` is the actual
    /// byte count for the C side to read the prefix.
    pub const ExtCount = struct {
        name: [16]u8,
        name_len: u8,
        count: u32,
    };

    /// Largest name length the reader can store. Matches the writer's
    /// `MAX_EXT_NAME_LEN` cap; on-disk exts longer than this are skipped
    /// defensively (a malformed index shouldn't crash the sidebar).
    pub const MAX_EXT_NAME_LEN: u8 = 15;

    /// Read up to `out.len` extension-count rows for the (dir_id, cat) bucket
    /// directly out of the on-disk column. The reader walks past earlier
    /// buckets to find the target — O(dir_count × categories) reads, all small
    /// (`u16` header + per-ext header), so the cost is bounded by the column
    /// layout, not the entry count. Returns the number of rows written.
    /// If `dir_id` is out of range or the column is truncated, writes 0 rows
    /// (the reader is defensive; callers should resolve via `findDirId` first).
    pub fn getFolderExtBreakdown(
        self: IndexReader,
        dir_id: u32,
        cat: u8,
        out: []ExtCount,
    ) usize {
        const num_dirs = self.dirCount() orelse return 0;
        if (dir_id >= num_dirs) return 0;
        if (cat >= types.FileCategory.count) return 0;
        if (out.len == 0) return 0;

        const col_start: usize = @intCast(self.header.ext_breakdown_offset);
        if (col_start >= self.data.len) return 0;

        // Walk past (dir_id × categories + cat) buckets.
        const target_bucket: u32 = @as(u32, dir_id) * types.FileCategory.count + cat;
        var pos: usize = col_start;
        var bucket: u32 = 0;
        while (bucket < target_bucket) : (bucket += 1) {
            if (pos + 2 > self.data.len) return 0;
            const num_exts = std.mem.readInt(u16, self.data[pos..][0..2], .little);
            pos += 2;
            if (!self.skipExts(pos, num_exts)) return 0;
            pos = self.bucketEnd(pos, num_exts);
        }
        return self.readBucketInto(pos, out);
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
    pub fn getSubtreeExtBreakdown(
        self: IndexReader,
        scope_path: []const u8,
        cat: u8,
        out: []ExtCount,
    ) usize {
        if (out.len == 0) return 0;
        if (cat >= types.FileCategory.count) return 0;

        const num_dirs = self.dirCount() orelse return 0;
        if (num_dirs == 0) return 0;

        const col_start: usize = @intCast(self.header.ext_breakdown_offset);
        if (col_start >= self.data.len) return 0;

        // Build a "is in subtree" bitmap keyed by dir_id. For the root
        // scope, all dirs are in; for subfolders, we walk the dir table once
        // to mark the descendants. The bitmap is a `[]u8` of size `num_dirs`,
        // where byte d is 1 if d is in the subtree. This lets the inner
        // merge loop test membership in O(1) with no allocations.
        const in_subtree = self.allocator.alloc(u8, num_dirs) catch return 0;
        defer self.allocator.free(in_subtree);
        @memset(in_subtree, 0);
        if (!self.markSubtreeDirs(scope_path, in_subtree)) return 0;

        // Single forward walk of the column. For each (dir_id, cat) bucket,
        // check if the bucket's cat matches AND dir_id is in the subtree. If
        // both, merge. Always advance past the bucket.
        var ext_storage = std.ArrayList(u8).empty;
        defer ext_storage.deinit(self.allocator);

        var merge = std.HashMap(KeyOff, u32, KeyOffContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer merge.deinit();

        var pos: usize = col_start;
        var d: u32 = 0;
        while (d < num_dirs) : (d += 1) {
            var c: u8 = 0;
            while (c < types.FileCategory.count) : (c += 1) {
                if (pos + 2 > self.data.len) return 0;
                const num_exts = std.mem.readInt(u16, self.data[pos..][0..2], .little);
                pos += 2;
                if (!self.skipExts(pos, num_exts)) return 0;
                const ext_end = self.bucketEnd(pos, num_exts);
                if (ext_end == 0) return 0;

                if (c == cat and in_subtree[d] != 0) {
                    var p: usize = pos;
                    while (p < ext_end) {
                        const len = self.data[p];
                        p += 1;
                        // Defensive: skip overflow ext names (see readBucketInto).
                        if (len > MAX_EXT_NAME_LEN) {
                            p += len + 4;
                            continue;
                        }
                        const name = self.data[p..@intCast(p + len)];
                        p += len;
                        const count = std.mem.readInt(u32, self.data[p..][0..4], .little);
                        p += 4;

                        const key = KeyOff{
                            .off = @intCast(ext_storage.items.len),
                            .len = @intCast(len),
                        };
                        const gop = merge.getOrPut(key) catch continue;
                        if (!gop.found_existing) {
                            ext_storage.appendSlice(self.allocator, name) catch continue;
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
        var scratch = std.ArrayList(ExtCount).empty;
        defer scratch.deinit(self.allocator);
        scratch.ensureTotalCapacity(self.allocator, merge.count()) catch return 0;
        var it = merge.iterator();
        while (it.next()) |entry| {
            const ko = entry.key_ptr.*;
            const n: usize = @intCast(ko.off + ko.len);
            var row = ExtCount{
                .name = undefined,
                .name_len = @intCast(ko.len),
                .count = entry.value_ptr.*,
            };
            @memcpy(row.name[0..ko.len], ext_storage.items[ko.off..n]);
            scratch.append(self.allocator, row) catch continue;
        }

        const lessExt = struct {
            fn f(_: void, a: ExtCount, b: ExtCount) bool {
                return a.count > b.count;
            }
        }.f;
        std.mem.sort(ExtCount, scratch.items, {}, lessExt);

        const n = @min(scratch.items.len, out.len);
        for (0..n) |i| out[i] = scratch.items[i];
        return n;
    }

    /// Mark `in_subtree[d] = 1` for every dir id that falls under
    /// `scope_path` (or every dir if `scope_path == "/"`). Returns false
    /// if the dir table is malformed.
    fn markSubtreeDirs(self: IndexReader, scope_path: []const u8, in_subtree: []u8) bool {
        const num = in_subtree.len;
        const parent_ids_start: usize = @intCast(self.header.paths_offset);
        const dir_count_offset = parent_ids_start + @as(usize, @intCast(self.header.num_entries)) * 4;
        const dir_count = std.mem.readInt(u32, self.data[dir_count_offset..][0..4], .little);
        const dir_offsets_start = dir_count_offset + 4;
        const dir_blob_len_pos = dir_offsets_start + dir_count * 4;
        if (dir_blob_len_pos + 4 > self.data.len) return false;
        const dir_blob_len = std.mem.readInt(u32, self.data[dir_blob_len_pos..][0..4], .little);
        const dir_blob_start = dir_blob_len_pos + 4;
        if (dir_blob_start + dir_blob_len > self.data.len) return false;

        const is_root_scope = scope_path.len == 1 and scope_path[0] == '/';
        var d: u32 = 0;
        while (d < num and d < dir_count) : (d += 1) {
            if (is_root_scope) {
                in_subtree[d] = 1;
                continue;
            }
            const off = std.mem.readInt(u32, self.data[dir_offsets_start + d * 4 ..][0..4], .little);
            const next: u32 = if (d + 1 < dir_count)
                std.mem.readInt(u32, self.data[dir_offsets_start + (d + 1) * 4 ..][0..4], .little)
            else
                dir_blob_len;
            if (next < off or next > dir_blob_len) continue;
            const path = self.data[dir_blob_start + off .. dir_blob_start + next];

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
    fn dirCount(self: IndexReader) ?u32 {
        const num: usize = @intCast(self.header.num_entries);
        const parent_ids_start: usize = @intCast(self.header.paths_offset);
        const dir_count_offset = parent_ids_start + num * 4;
        if (dir_count_offset + 4 > self.data.len) return null;
        return std.mem.readInt(u32, self.data[dir_count_offset..][0..4], .little);
    }

    /// Read the bucket starting at `pos` (which points to the `u16 num_exts`
    /// header) into `out`, writing up to `out.len` rows. Returns the number
    /// of rows written. The bucket's actual size may exceed `out.len` — the
    /// caller is responsible for picking a buffer that fits their needs.
    /// Names are copied into the fixed-size `ExtCount.name` buffer so the
    /// output rows are self-owned and don't depend on the index mmap.
    fn readBucketInto(self: IndexReader, pos: usize, out: []ExtCount) usize {
        if (pos + 2 > self.data.len) return 0;
        const num_exts = std.mem.readInt(u16, self.data[pos..][0..2], .little);
        if (num_exts == 0) return 0;
        const ext_start = pos + 2;
        const ext_end = self.bucketEnd(ext_start, num_exts);
        if (ext_end == 0 or ext_end > self.data.len) return 0;

        var i: usize = 0;
        var p: usize = ext_start;
        while (p < ext_end and i < out.len) : (i += 1) {
            const len = self.data[p];
            p += 1;
            // Skip overflow ext names defensively (a stale or malformed
            // index written before the 15-byte cap shouldn't crash the
            // sidebar). We still advance past the entry, so the bucket
            // walker stays in sync.
            if (len > MAX_EXT_NAME_LEN) {
                p += len + 4;
                i -= 1;
                continue;
            }
            const name_src = self.data[p..@intCast(p + len)];
            p += len;
            const count = std.mem.readInt(u32, self.data[p..][0..4], .little);
            p += 4;
            var row: ExtCount = .{
                .name = undefined,
                .name_len = len,
                .count = count,
            };
            @memcpy(row.name[0..len], name_src);
            out[i] = row;
        }
        return i;
    }

    /// Compute the byte position just past `num_exts` ext entries starting at
    /// `ext_start`. Returns 0 if the column is truncated.
    fn bucketEnd(self: IndexReader, ext_start: usize, num_exts: u16) usize {
        var p = ext_start;
        var i: u16 = 0;
        while (i < num_exts) : (i += 1) {
            if (p + 1 > self.data.len) return 0;
            const len = self.data[p];
            p += 1;
            p += len;
            p += 4; // u32 count
            if (p > self.data.len) return 0;
        }
        return p;
    }

    /// Bounds check: would advancing past `num_exts` ext entries starting at
    /// `ext_start` fall inside `data`? Cheap, no allocations.
    fn skipExts(self: IndexReader, ext_start: usize, num_exts: u16) bool {
        var p = ext_start;
        var i: u16 = 0;
        while (i < num_exts) : (i += 1) {
            if (p + 1 > self.data.len) return false;
            const len = self.data[p];
            p += 1 + len + 4;
            if (p > self.data.len) return false;
        }
        return true;
    }

    pub fn openFile(allocator: std.mem.Allocator, path: []const u8) !IndexReader {
        const data = try runtime.readFileAlloc(allocator, path, .unlimited);
        if (data.len < format.HEADER_SIZE) {
            allocator.free(data);
            return error.IndexTooSmall;
        }
        return try init(allocator, data);
    }
};
