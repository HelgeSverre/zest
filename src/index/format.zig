const std = @import("std");
const types = @import("../core/types.zig");
const runtime = @import("../core/runtime.zig");

pub const MAGIC: u64 = 0x5A455354494E4458; // "ZESTINDX"
pub const VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 64;

pub const Header = struct {
    magic: u64,
    version: u32,
    num_entries: u64,
    created_at: u64,
    names_offset: u64,
    paths_offset: u64,
    meta_offset: u64,
    bitmap_offset: u64,

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

    for (entries, 0..) |entry, i| {
        const gop = try dir_table.getOrPut(entry.dir_path);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(dir_list.items.len);
            try dir_list.append(allocator, entry.dir_path);
        }
        parent_ids[i] = gop.value_ptr.*;
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

    // === Metadata Column ===
    const meta_offset: u64 = buf.items.len;

    for (entries) |entry| try writer.writeInt(u64, entry.size, .little);
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
    };

    var header_buf: [HEADER_SIZE]u8 = undefined;
    var header_writer = std.Io.Writer.fixed(&header_buf);
    try header.serialize(&header_writer);
    @memcpy(buf.items[0..HEADER_SIZE], &header_buf);

    return buf.toOwnedSlice(allocator);
}
