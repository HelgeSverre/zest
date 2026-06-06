const std = @import("std");
const types = @import("../core/types.zig");
const format = @import("format.zig");
const bitmap_mod = @import("bitmap.zig");
const runtime = @import("../core/runtime.zig");

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

    pub fn openFile(allocator: std.mem.Allocator, path: []const u8) !IndexReader {
        const data = try runtime.readFileAlloc(allocator, path, .unlimited);
        if (data.len < format.HEADER_SIZE) {
            allocator.free(data);
            return error.IndexTooSmall;
        }
        return try init(allocator, data);
    }
};
