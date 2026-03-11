const std = @import("std");
const types = @import("../core/types.zig");

/// Simple sorted-array bitmap for category/extension filtering.
pub const Bitmap = struct {
    indices: []const u32,
    allocator: ?std.mem.Allocator,

    pub fn initOwned(allocator: std.mem.Allocator, indices: []u32) Bitmap {
        std.mem.sort(u32, indices, {}, std.sort.asc(u32));
        return .{ .indices = indices, .allocator = allocator };
    }

    pub fn initBorrowed(indices: []const u32) Bitmap {
        return .{ .indices = indices, .allocator = null };
    }

    pub fn deinit(self: *Bitmap) void {
        if (self.allocator) |alloc| {
            alloc.free(@constCast(self.indices));
        }
    }

    pub fn contains(self: Bitmap, value: u32) bool {
        var lo: usize = 0;
        var hi: usize = self.indices.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.indices[mid] < value) {
                lo = mid + 1;
            } else if (self.indices[mid] > value) {
                hi = mid;
            } else {
                return true;
            }
        }
        return false;
    }

    pub fn count(self: Bitmap) usize {
        return self.indices.len;
    }

    pub fn intersect(allocator: std.mem.Allocator, a: Bitmap, b: Bitmap) !Bitmap {
        var result: std.ArrayList(u32) = .empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        var j: usize = 0;
        while (i < a.indices.len and j < b.indices.len) {
            if (a.indices[i] == b.indices[j]) {
                try result.append(allocator, a.indices[i]);
                i += 1;
                j += 1;
            } else if (a.indices[i] < b.indices[j]) {
                i += 1;
            } else {
                j += 1;
            }
        }

        return .{ .indices = try result.toOwnedSlice(allocator), .allocator = allocator };
    }

    pub fn merge(allocator: std.mem.Allocator, a: Bitmap, b: Bitmap) !Bitmap {
        var result: std.ArrayList(u32) = .empty;
        errdefer result.deinit(allocator);

        var i: usize = 0;
        var j: usize = 0;
        while (i < a.indices.len and j < b.indices.len) {
            if (a.indices[i] == b.indices[j]) {
                try result.append(allocator, a.indices[i]);
                i += 1;
                j += 1;
            } else if (a.indices[i] < b.indices[j]) {
                try result.append(allocator, a.indices[i]);
                i += 1;
            } else {
                try result.append(allocator, b.indices[j]);
                j += 1;
            }
        }
        while (i < a.indices.len) : (i += 1) try result.append(allocator, a.indices[i]);
        while (j < b.indices.len) : (j += 1) try result.append(allocator, b.indices[j]);

        return .{ .indices = try result.toOwnedSlice(allocator), .allocator = allocator };
    }

    pub fn iterator(self: Bitmap) Iterator {
        return .{ .bitmap = self, .pos = 0 };
    }

    pub const Iterator = struct {
        bitmap: Bitmap,
        pos: usize,

        pub fn next(self: *Iterator) ?u32 {
            if (self.pos >= self.bitmap.indices.len) return null;
            const val = self.bitmap.indices[self.pos];
            self.pos += 1;
            return val;
        }
    };
};

pub fn readCategoryBitmaps(allocator: std.mem.Allocator, data: []const u8, bitmap_offset: usize) !std.AutoHashMap(types.FileCategory, Bitmap) {
    var map = std.AutoHashMap(types.FileCategory, Bitmap).init(allocator);
    errdefer map.deinit();

    var pos = bitmap_offset;
    if (pos + 4 > data.len) return map;

    const num_bitmaps = std.mem.readInt(u32, data[pos..][0..4], .little);
    pos += 4;

    for (0..num_bitmaps) |_| {
        if (pos + 5 > data.len) break;
        const cat_byte = data[pos];
        pos += 1;
        const cnt = std.mem.readInt(u32, data[pos..][0..4], .little);
        pos += 4;

        const end = pos + cnt * 4;
        if (end > data.len) break;

        const aligned = try allocator.alloc(u32, cnt);
        for (0..cnt) |i| {
            aligned[i] = std.mem.readInt(u32, data[pos + i * 4 ..][0..4], .little);
        }

        const cat: types.FileCategory = @enumFromInt(cat_byte);
        try map.put(cat, .{ .indices = aligned, .allocator = allocator });
        pos = end;
    }

    return map;
}
