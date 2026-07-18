const std = @import("std");
const types = @import("../core/types.zig");
const runtime = @import("../core/runtime.zig");

pub const MAGIC: u64 = 0x5A455354494E4458; // "ZESTINDX"
/// v2: per-folder × per-category histogram column.
/// v3: per-(folder × category) extension breakdown column.
/// v4: directory entries' size = recursive subtree total (layout unchanged;
///     the bump forces a reindex so folders never show stale zeros).
/// v5: category semantics add `.sema` to Code (layout unchanged; restart the
///     daemon and run `just index` so existing rows receive the new category).
/// Reader's version check rejects old indexes; version bumps require a rebuild before use.
pub const VERSION: u32 = 5;
/// 8 (magic) + 4 (version) + 4 (padding) + 8 × 8 (u64 offsets: num_entries,
/// created_at, names, paths, meta, bitmap, histogram, ext_breakdown) = 80 bytes.
pub const HEADER_SIZE: usize = 80;

/// Maximum number of unique extensions stored per (folder, category) bucket.
/// 32 is generous for typical folders (most have 3-10 unique exts per category)
/// and keeps the column compact. Folders with more (e.g. `node_modules`) are
/// truncated to the top-32 by count.
pub const MAX_EXTS_PER_BUCKET: u16 = 32;

/// Maximum length of an extension name stored in the on-disk column. Capped
/// to 15 bytes so it fits the reader's fixed-size `ExtCount.name: [16]u8`
/// buffer (room for the longest realistic ext like `.swiftinterface` = 14
/// chars). Longer exts (rare) are dropped from the breakdown.
pub const MAX_EXT_NAME_LEN: u8 = 15;

pub const Header = struct {
    magic: u64,
    version: u32,
    num_entries: u64,
    created_at: u64,
    names_offset: u64,
    paths_offset: u64,
    meta_offset: u64,
    bitmap_offset: u64,
    /// Per-folder × per-category counts column. Layout: `u32[FileCategory.count]`
    /// for each of the `dir_count` directories in the paths table. O(1) sidebar
    /// histogram reads.
    histogram_offset: u64,
    /// Per-(folder × category) extension breakdown. Layout: for each of the
    /// `dir_count` directories, for each of the `FileCategory.count` categories,
    /// a `u16 num_exts` (≤ MAX_EXTS_PER_BUCKET) followed by `num_exts` entries
    /// of `(u8 len, u8[len] bytes, u32 count)`. O(1) per-folder read; O(D) merge
    /// for subtree scopes.
    ext_breakdown_offset: u64,

    pub fn serialize(self: Header, writer: anytype) !void {
        try writer.writeInt(u64, self.magic, .little);
        try writer.writeInt(u32, self.version, .little);
        try writer.writeInt(u32, 0, .little); // padding
        try writer.writeInt(u64, self.num_entries, .little);
        try writer.writeInt(u64, self.created_at, .little);
        try writer.writeInt(u64, self.names_offset, .little);
        try writer.writeInt(u64, self.paths_offset, .little);
        try writer.writeInt(u64, self.meta_offset, .little);
        try writer.writeInt(u64, self.bitmap_offset, .little);
        try writer.writeInt(u64, self.histogram_offset, .little);
        try writer.writeInt(u64, self.ext_breakdown_offset, .little);
    }

    pub fn deserialize(reader: anytype) !Header {
        const magic = try reader.takeInt(u64, .little);
        if (magic != MAGIC) return error.InvalidMagic;
        const version = try reader.takeInt(u32, .little);
        if (version != VERSION) return error.UnsupportedVersion;
        _ = try reader.takeInt(u32, .little); // padding
        return .{
            .magic = magic,
            .version = version,
            .num_entries = try reader.takeInt(u64, .little),
            .created_at = try reader.takeInt(u64, .little),
            .names_offset = try reader.takeInt(u64, .little),
            .paths_offset = try reader.takeInt(u64, .little),
            .meta_offset = try reader.takeInt(u64, .little),
            .bitmap_offset = try reader.takeInt(u64, .little),
            .histogram_offset = try reader.takeInt(u64, .little),
            .ext_breakdown_offset = try reader.takeInt(u64, .little),
        };
    }
};

pub const IndexEntry = struct {
    name: []const u8,
    dir_path: []const u8,
    size: u64,
    mtime: i64,
    kind: types.FileKind,
    category: types.FileCategory,
};

/// Little-endian append helper over an `ArrayList(u8)`. Zig 0.16 dropped
/// `ArrayList.writer`, and this column format needs to read `buf.items.len`
/// between writes, so a direct-append shim is simpler than a buffered writer.
const BufWriter = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn writeInt(self: BufWriter, comptime T: type, value: T, endian: std.builtin.Endian) !void {
        var bytes: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &bytes, value, endian);
        try self.buf.appendSlice(self.allocator, &bytes);
    }

    fn writeAll(self: BufWriter, bytes: []const u8) !void {
        try self.buf.appendSlice(self.allocator, bytes);
    }

    fn writeByte(self: BufWriter, value: u8) !void {
        try self.buf.append(self.allocator, value);
    }
};

/// Escape backslash, tab, and newline for the TSV scan records
/// ('\\'→"\\\\", '\t'→"\\t", '\n'→"\\n").
/// Returns null if `out` is too small (caller should skip the entry).
pub fn escapeTsv(out: []u8, s: []const u8) ?[]const u8 {
    var di: usize = 0;
    for (s) |ch| {
        switch (ch) {
            '\\' => {
                if (di + 2 > out.len) return null;
                out[di] = '\\';
                out[di + 1] = '\\';
                di += 2;
            },
            '\t' => {
                if (di + 2 > out.len) return null;
                out[di] = '\\';
                out[di + 1] = 't';
                di += 2;
            },
            '\n' => {
                if (di + 2 > out.len) return null;
                out[di] = '\\';
                out[di + 1] = 'n';
                di += 2;
            },
            else => {
                if (di + 1 > out.len) return null;
                out[di] = ch;
                di += 1;
            },
        }
    }
    return out[0..di];
}

/// Inverse of escapeTsv. Decodes "\\\\", "\\t", "\\n" back to their
/// original characters. `out` may alias a buffer >= s.len.
/// Unknown escape sequences (e.g. "\\x") are left as-is (the backslash
/// and the following char are both copied).
pub fn unescapeTsv(out: []u8, s: []const u8) []const u8 {
    var si: usize = 0;
    var di: usize = 0;
    while (si < s.len) {
        if (s[si] == '\\' and si + 1 < s.len) {
            switch (s[si + 1]) {
                '\\' => {
                    out[di] = '\\';
                    di += 1;
                    si += 2;
                },
                't' => {
                    out[di] = '\t';
                    di += 1;
                    si += 2;
                },
                'n' => {
                    out[di] = '\n';
                    di += 1;
                    si += 2;
                },
                else => {
                    out[di] = s[si];
                    di += 1;
                    si += 1;
                },
            }
        } else {
            out[di] = s[si];
            di += 1;
            si += 1;
        }
    }
    return out[0..di];
}

// -------------------------------------------------------------------------
// Tests
// -------------------------------------------------------------------------

test "escapeTsv / unescapeTsv round-trip with tab, newline, backslash" {
    const original = "we\tird\nna\\me";
    var esc_buf: [original.len * 2]u8 = undefined;
    const escaped = escapeTsv(&esc_buf, original) orelse return error.TestUnexpectedResult;

    // Escaped form must not contain raw tab or newline
    for (escaped) |ch| {
        try std.testing.expect(ch != '\t');
        try std.testing.expect(ch != '\n');
    }

    // Round-trip: split on \t (none in escaped) then unescape
    var unesc_buf: [original.len * 2]u8 = undefined;
    const roundtrip = unescapeTsv(&unesc_buf, escaped);
    try std.testing.expectEqualStrings(original, roundtrip);
}

test "writeIndex bakes recursive folder sizes into directory entries" {
    const reader_mod = @import("reader.zig");
    const entries = [_]IndexEntry{
        .{ .name = "a.txt", .dir_path = "/home/u/docs", .size = 100, .mtime = 1, .kind = .file, .category = .text },
        .{ .name = "b.txt", .dir_path = "/home/u/docs", .size = 20, .mtime = 1, .kind = .file, .category = .text },
        .{ .name = "c.txt", .dir_path = "/home/u/docs/sub", .size = 3, .mtime = 1, .kind = .file, .category = .text },
        .{ .name = "sub", .dir_path = "/home/u/docs", .size = 0, .mtime = 1, .kind = .directory, .category = .uncategorized },
        .{ .name = "docs", .dir_path = "/home/u", .size = 0, .mtime = 1, .kind = .directory, .category = .uncategorized },
        .{ .name = "top.txt", .dir_path = "/home/u", .size = 4000, .mtime = 1, .kind = .file, .category = .text },
    };
    const data = try writeIndex(std.testing.allocator, &entries);
    defer std.testing.allocator.free(data);
    var reader = try reader_mod.IndexReader.init(std.testing.allocator, data);
    defer reader.deinit();

    // Files keep their own sizes.
    try std.testing.expectEqual(@as(u64, 100), reader.getMeta(0).?.size);
    try std.testing.expectEqual(@as(u64, 3), reader.getMeta(2).?.size);
    // "sub" = its one file; "docs" = its files + sub's subtree.
    try std.testing.expectEqual(@as(u64, 3), reader.getMeta(3).?.size);
    try std.testing.expectEqual(@as(u64, 123), reader.getMeta(4).?.size);
}

test "writeIndex gives an empty directory size zero" {
    const reader_mod = @import("reader.zig");
    const entries = [_]IndexEntry{
        .{ .name = "empty", .dir_path = "/home/u", .size = 999, .mtime = 1, .kind = .directory, .category = .uncategorized },
        .{ .name = "f.txt", .dir_path = "/home/u", .size = 7, .mtime = 1, .kind = .file, .category = .text },
    };
    const data = try writeIndex(std.testing.allocator, &entries);
    defer std.testing.allocator.free(data);
    var reader = try reader_mod.IndexReader.init(std.testing.allocator, data);
    defer reader.deinit();

    // The scanner-reported dir st_size (999 here) is discarded; nothing is
    // indexed under /home/u/empty, so its subtree size is 0.
    try std.testing.expectEqual(@as(u64, 0), reader.getMeta(0).?.size);
}

test "writeIndex folder sizes do not bleed between sibling-prefix dirs" {
    const reader_mod = @import("reader.zig");
    const entries = [_]IndexEntry{
        .{ .name = "x.txt", .dir_path = "/a/b", .size = 1, .mtime = 1, .kind = .file, .category = .text },
        .{ .name = "y.txt", .dir_path = "/a/bc", .size = 10, .mtime = 1, .kind = .file, .category = .text },
        .{ .name = "b", .dir_path = "/a", .size = 0, .mtime = 1, .kind = .directory, .category = .uncategorized },
        .{ .name = "bc", .dir_path = "/a", .size = 0, .mtime = 1, .kind = .directory, .category = .uncategorized },
    };
    const data = try writeIndex(std.testing.allocator, &entries);
    defer std.testing.allocator.free(data);
    var reader = try reader_mod.IndexReader.init(std.testing.allocator, data);
    defer reader.deinit();

    try std.testing.expectEqual(@as(u64, 1), reader.getMeta(2).?.size); // b
    try std.testing.expectEqual(@as(u64, 10), reader.getMeta(3).?.size); // bc
}

test "escapeTsv returns null when output buffer too small" {
    var tiny: [2]u8 = undefined;
    const result = escapeTsv(&tiny, "ab\\cd");
    try std.testing.expect(result == null);
}

pub fn writeIndex(allocator: std.mem.Allocator, entries: []const IndexEntry) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = BufWriter{ .buf = &buf, .allocator = allocator };

    const num = entries.len;

    // Reserve header space
    try buf.appendNTimes(allocator, 0, HEADER_SIZE);

    // === Names Column ===
    const names_offset: u64 = buf.items.len;

    var name_offsets = try allocator.alloc(u32, num);
    defer allocator.free(name_offsets);
    var name_lengths = try allocator.alloc(u16, num);
    defer allocator.free(name_lengths);

    var name_blob: std.ArrayList(u8) = .empty;
    defer name_blob.deinit(allocator);
    var lower_blob: std.ArrayList(u8) = .empty;
    defer lower_blob.deinit(allocator);

    // Pre-size the name blobs (~16 bytes/name heuristic) to avoid repeated
    // doubling reallocations while appending millions of entries.
    try name_blob.ensureTotalCapacity(allocator, num * 16);
    try lower_blob.ensureTotalCapacity(allocator, num * 16);

    for (entries, 0..) |entry, i| {
        name_offsets[i] = @intCast(name_blob.items.len);
        name_lengths[i] = @intCast(entry.name.len);
        try name_blob.appendSlice(allocator, entry.name);
        for (entry.name) |ch| {
            try lower_blob.append(allocator, std.ascii.toLower(ch));
        }
    }

    for (name_offsets) |off| try writer.writeInt(u32, off, .little);
    for (name_lengths) |len| try writer.writeInt(u16, len, .little);
    try writer.writeInt(u32, @intCast(name_blob.items.len), .little);
    try writer.writeAll(name_blob.items);
    try writer.writeInt(u32, @intCast(lower_blob.items.len), .little);
    try writer.writeAll(lower_blob.items);

    // === Paths Column ===
    const paths_offset: u64 = buf.items.len;

    var dir_table = std.StringHashMap(u32).init(allocator);
    defer dir_table.deinit();
    var dir_list: std.ArrayList([]const u8) = .empty;
    defer dir_list.deinit(allocator);

    var parent_ids = try allocator.alloc(u32, num);
    defer allocator.free(parent_ids);

    // Per-folder × per-category histogram buffer. Indexed `[dir_id][cat]`.
    // Pre-allocated to a generous capacity (we'll know the exact size after
    // the entries loop resolves all unique dirs). Filled inline in the loop
    // below — no second pass over entries.
    var hist = try allocator.alloc(
        u32,
        @as(usize, num) * types.FileCategory.count,
    );
    defer allocator.free(hist);
    @memset(hist, 0);

    for (entries, 0..) |entry, i| {
        const gop = try dir_table.getOrPut(entry.dir_path);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(dir_list.items.len);
            try dir_list.append(allocator, entry.dir_path);
        }
        const pid: u32 = gop.value_ptr.*;
        parent_ids[i] = pid;
        hist[@as(usize, pid) * types.FileCategory.count + @intFromEnum(entry.category)] += 1;
    }

    for (parent_ids) |pid| try writer.writeInt(u32, pid, .little);
    try writer.writeInt(u32, @intCast(dir_list.items.len), .little);

    var dir_offsets: std.ArrayList(u32) = .empty;
    defer dir_offsets.deinit(allocator);
    var dir_blob: std.ArrayList(u8) = .empty;
    defer dir_blob.deinit(allocator);

    try dir_offsets.ensureTotalCapacity(allocator, dir_list.items.len);

    for (dir_list.items) |d| {
        try dir_offsets.append(allocator, @intCast(dir_blob.items.len));
        try dir_blob.appendSlice(allocator, d);
    }

    for (dir_offsets.items) |off| try writer.writeInt(u32, off, .little);
    try writer.writeInt(u32, @intCast(dir_blob.items.len), .little);
    try writer.writeAll(dir_blob.items);

    // === Recursive folder sizes ===
    // Files keep their scanned size; directory entries get their subtree
    // total (the scanner writes 0 for dirs — DATALENGTH is absent for them).
    // Local per-dir sums roll up child→parent in path-length-descending
    // order: a child's path is strictly longer than its parent's, so length
    // order is a valid bottom-up topological order.
    var sizes = try allocator.alloc(u64, num);
    defer allocator.free(sizes);

    var dir_totals = try allocator.alloc(u64, dir_list.items.len);
    defer allocator.free(dir_totals);
    @memset(dir_totals, 0);

    for (entries, 0..) |entry, i| {
        sizes[i] = entry.size;
        if (entry.kind != .directory) dir_totals[parent_ids[i]] += entry.size;
    }

    const roll_order = try allocator.alloc(u32, dir_list.items.len);
    defer allocator.free(roll_order);
    for (roll_order, 0..) |*o, i| o.* = @intCast(i);
    const deeperFirst = struct {
        fn f(paths: []const []const u8, a: u32, b: u32) bool {
            return paths[a].len > paths[b].len;
        }
    }.f;
    std.mem.sort(u32, roll_order, @as([]const []const u8, dir_list.items), deeperFirst);

    for (roll_order) |d| {
        const dpath = dir_list.items[d];
        const slash = std.mem.lastIndexOfScalar(u8, dpath, '/') orelse continue;
        // "/x" → "/"; deeper paths cut at the last slash. Roll-up stops
        // naturally when the parent isn't in the table (scan root's parent).
        const parent = if (slash == 0) dpath[0..1] else dpath[0..slash];
        const pid = dir_table.get(parent) orelse continue;
        if (pid == d) continue; // "/" is its own dirname
        dir_totals[pid] += dir_totals[d];
    }

    // Directory entries own the total of the dir-table row matching their
    // full path. Dirs with no indexed content have no row → 0.
    var dir_path_buf: std.ArrayList(u8) = .empty;
    defer dir_path_buf.deinit(allocator);
    for (entries, 0..) |entry, i| {
        if (entry.kind != .directory) continue;
        dir_path_buf.clearRetainingCapacity();
        try dir_path_buf.appendSlice(allocator, entry.dir_path);
        if (dir_path_buf.items.len == 0 or dir_path_buf.items[dir_path_buf.items.len - 1] != '/')
            try dir_path_buf.append(allocator, '/');
        try dir_path_buf.appendSlice(allocator, entry.name);
        sizes[i] = if (dir_table.get(dir_path_buf.items)) |d| dir_totals[d] else 0;
    }

    // === Metadata Column ===
    const meta_offset: u64 = buf.items.len;

    for (sizes) |s| try writer.writeInt(u64, s, .little);
    for (entries) |entry| try writer.writeInt(i64, entry.mtime, .little);
    for (entries) |entry| try writer.writeByte(@intFromEnum(entry.kind));
    for (entries) |entry| try writer.writeByte(@intFromEnum(entry.category));

    // === Bitmaps ===
    const bitmap_offset: u64 = buf.items.len;

    var category_entries: [types.FileCategory.count]std.ArrayList(u32) = undefined;
    for (0..types.FileCategory.count) |i| {
        category_entries[i] = .empty;
    }
    defer for (&category_entries) |*list| list.deinit(allocator);

    for (entries, 0..) |entry, i| {
        try category_entries[@intFromEnum(entry.category)].append(allocator, @intCast(i));
    }

    var num_bitmaps: u32 = 0;
    for (category_entries) |list| {
        if (list.items.len > 0) num_bitmaps += 1;
    }
    try writer.writeInt(u32, num_bitmaps, .little);

    for (category_entries, 0..) |list, cat_idx| {
        if (list.items.len == 0) continue;
        try writer.writeByte(@intCast(cat_idx));
        try writer.writeInt(u32, @intCast(list.items.len), .little);
        for (list.items) |idx| try writer.writeInt(u32, idx, .little);
    }

    // === Histogram (per-folder × per-category counts) ===
    // Layout: `u32[FileCategory.count]` for each of the `dir_count` directories,
    // in the same order as the dir table. Used by `zest_histogram` for the
    // sidebar's O(1) per-folder read.
    const histogram_offset: u64 = buf.items.len;
    const hist_count: usize = dir_list.items.len * types.FileCategory.count;
    for (hist[0..hist_count]) |c| try writer.writeInt(u32, c, .little);

    // === Extension Breakdown (per-folder × per-category × top-N exts) ===
    // Build it in a second pass over entries: we now know `dir_count`, so we
    // can allocate the per-bucket accumulator array in one shot. Each bucket
    // is sorted by count (descending) and truncated to MAX_EXTS_PER_BUCKET.
    const StableExt = struct {
        name_off: u32,
        name_len: u8,
        count: u32,
    };

    var keys_buf = std.ArrayList(u8).empty;
    defer keys_buf.deinit(allocator);
    try keys_buf.ensureTotalCapacity(allocator, num * 8);

    var ext_buckets = try allocator.alloc(
        std.ArrayList(StableExt),
        dir_list.items.len * types.FileCategory.count,
    );
    defer {
        for (ext_buckets) |*list| list.deinit(allocator);
        allocator.free(ext_buckets);
    }
    for (ext_buckets) |*list| list.* = .empty;

    var lower_buf: [31]u8 = undefined;
    for (entries) |entry| {
        // Lowercased extension: bytes after the last dot, or skip if no ext.
        // Capped at 15 bytes so it fits the reader's fixed-size
        // `ExtCount.name: [16]u8` buffer (one slot for the length byte
        // and a trailing NUL isn't needed; the reader's `name_len`
        // reports the actual prefix).
        const dot_idx = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        if (dot_idx + 1 >= entry.name.len) continue;
        const raw = entry.name[dot_idx + 1 ..];
        if (raw.len == 0 or raw.len > 15) continue;
        for (raw, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
        const ext_lower: []const u8 = lower_buf[0..raw.len];

        const dir_id = dir_table.get(entry.dir_path) orelse continue;
        const cat: u8 = @intFromEnum(entry.category);
        const bucket = &ext_buckets[@as(usize, dir_id) * types.FileCategory.count + cat];

        // Linear scan of the bucket. Most buckets have <10 exts; the
        // MAX_EXTS_PER_BUCKET cap is only reached in dev folders.
        var found: ?usize = null;
        for (bucket.items, 0..) |e, i| {
            const existing = keys_buf.items[e.name_off..@intCast(e.name_off + e.name_len)];
            if (std.mem.eql(u8, existing, ext_lower)) {
                found = i;
                break;
            }
        }
        if (found) |i| {
            bucket.items[i].count += 1;
        } else {
            const off: u32 = @intCast(keys_buf.items.len);
            try keys_buf.appendSlice(allocator, ext_lower);
            try bucket.append(allocator, .{
                .name_off = off,
                .name_len = @intCast(ext_lower.len),
                .count = 1,
            });
        }
    }

    // Sort each bucket by count desc; truncate to MAX_EXTS_PER_BUCKET.
    const lessExt = struct {
        fn f(_: void, a: StableExt, b: StableExt) bool {
            return a.count > b.count;
        }
    }.f;
    for (ext_buckets) |*bucket| {
        std.mem.sort(StableExt, bucket.items, {}, lessExt);
        if (bucket.items.len > MAX_EXTS_PER_BUCKET) {
            bucket.shrinkRetainingCapacity(MAX_EXTS_PER_BUCKET);
        }
    }

    // Emit the column. Layout: for each (dir_id, cat) in [0, dir_count) ×
    // [0, FileCategory.count), `u16 num_exts` followed by `num_exts` entries
    // of `(u8 len, u8[len] bytes, u32 count)`. Self-describing: reader walks
    // the structure in order.
    const ext_breakdown_offset: u64 = buf.items.len;
    for (ext_buckets) |bucket| {
        try writer.writeInt(u16, @intCast(bucket.items.len), .little);
        for (bucket.items) |e| {
            try writer.writeByte(e.name_len);
            try writer.writeAll(keys_buf.items[e.name_off..@intCast(e.name_off + e.name_len)]);
            try writer.writeInt(u32, e.count, .little);
        }
    }

    // === Write header ===
    const now: u64 = @intCast(runtime.unixTimestamp());
    const header = Header{
        .magic = MAGIC,
        .version = VERSION,
        .num_entries = @intCast(num),
        .created_at = now,
        .names_offset = names_offset,
        .paths_offset = paths_offset,
        .meta_offset = meta_offset,
        .bitmap_offset = bitmap_offset,
        .histogram_offset = histogram_offset,
        .ext_breakdown_offset = ext_breakdown_offset,
    };

    var header_buf: [HEADER_SIZE]u8 = undefined;
    var header_writer = std.Io.Writer.fixed(&header_buf);
    try header.serialize(&header_writer);
    @memcpy(buf.items[0..HEADER_SIZE], &header_buf);

    return buf.toOwnedSlice(allocator);
}
