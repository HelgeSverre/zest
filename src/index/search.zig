const std = @import("std");
const types = @import("../core/types.zig");
const reader_mod = @import("reader.zig");
const bitmap_mod = @import("bitmap.zig");

pub const SearchOptions = struct {
    query: []const u8,
    category: ?types.FileCategory = null,
    max_results: u32 = 100,
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

pub fn search(allocator: std.mem.Allocator, reader: *reader_mod.IndexReader, opts: SearchOptions) ![]SearchResult {
    if (opts.query.len == 0) return try allocator.alloc(SearchResult, 0);

    var lower_query_buf: [256]u8 = undefined;
    if (opts.query.len > lower_query_buf.len) return error.QueryTooLong;
    for (opts.query, 0..) |ch, i| {
        lower_query_buf[i] = std.ascii.toLower(ch);
    }
    const lower_query = lower_query_buf[0..opts.query.len];

    const blob_info = reader.getLowerNameBlob() orelse return try allocator.alloc(SearchResult, 0);
    const blob = blob_info.blob;
    const num_entries: u32 = @intCast(reader.numEntries());

    var cat_bitmap: ?bitmap_mod.Bitmap = null;
    if (opts.category) |cat| {
        var bitmaps = try reader.getCategoryBitmaps();
        cat_bitmap = bitmaps.get(cat);
    }

    var results: std.ArrayList(SearchResult) = .empty;
    errdefer results.deinit(allocator);

    if (lower_query.len <= blob.len) {
        const first_char = lower_query[0];
        const last_char = lower_query[lower_query.len - 1];
        const qlen = lower_query.len;

        var pos: usize = 0;
        while (pos + qlen <= blob.len and results.items.len < opts.max_results) {
            if (blob[pos] == first_char and blob[pos + qlen - 1] == last_char) {
                if (std.mem.eql(u8, blob[pos .. pos + qlen], lower_query)) {
                    if (findEntryForBlobPos(reader, @intCast(pos), num_entries)) |entry_idx| {
                        var duplicate = false;
                        for (results.items) |r| {
                            if (r.index == entry_idx) {
                                duplicate = true;
                                break;
                            }
                        }

                        if (!duplicate) {
                            if (cat_bitmap) |bm| {
                                if (!bm.contains(entry_idx)) {
                                    pos += 1;
                                    continue;
                                }
                            }

                            if (buildResult(reader, entry_idx)) |result| {
                                try results.append(allocator, result);
                            }
                        }
                    }
                }
            }
            pos += 1;
        }
    }

    return results.toOwnedSlice(allocator);
}

fn findEntryForBlobPos(reader: *reader_mod.IndexReader, blob_pos: u32, num_entries: u32) ?u32 {
    const names_start: usize = @intCast(reader.header.names_offset);
    const offsets_start = names_start;
    const data = reader.data;

    var lo: u32 = 0;
    var hi: u32 = num_entries;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const off = std.mem.readInt(u32, data[offsets_start + mid * 4 ..][0..4], .little);
        if (off <= blob_pos) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    if (lo == 0) return null;
    const entry_idx = lo - 1;

    const entry_offset = std.mem.readInt(u32, data[offsets_start + entry_idx * 4 ..][0..4], .little);
    const lengths_start = offsets_start + num_entries * 4;
    const entry_len = std.mem.readInt(u16, data[lengths_start + entry_idx * 2 ..][0..2], .little);

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
