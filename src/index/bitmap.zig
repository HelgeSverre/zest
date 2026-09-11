const std = @import("std");
const types = @import("../core/types.zig");

/// Simple sorted-array bitmap for category/extension filtering.
pub const Bitmap = struct {
    indices: []const u32,
    allocator: ?std.mem.Allocator,

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

        const end = pos + @as(usize, cnt) * 4;
        if (end > data.len) break;

        const cat = std.enums.fromInt(types.FileCategory, cat_byte) orelse {
            pos = end;
            continue;
        };

        const aligned = try allocator.alloc(u32, cnt);
        for (0..cnt) |i| {
            aligned[i] = std.mem.readInt(u32, data[pos + i * 4 ..][0..4], .little);
        }

        try map.put(cat, .{ .indices = aligned, .allocator = allocator });
        pos = end;
    }

    return map;
}
