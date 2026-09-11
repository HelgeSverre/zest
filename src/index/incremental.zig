//! Incremental rebuild: relist the directories FSEvents reported, splice them
//! into the previous index's entries, and let `writeIndex` re-derive folder
//! sizes, histograms, and extension buckets. A full walk of a home directory
//! costs ~20 s and ~60 CPU-seconds of kernel time; relisting a few dirs is ms.
const std = @import("std");
const format = @import("format.zig");
const reader_mod = @import("reader.zig");
const builder = @import("builder.zig");
const bulk_scan = @import("bulk_scan.zig");
const config = @import("../config/config.zig");
const core_paths = @import("../core/paths.zig");
const runtime = @import("../core/runtime.zig");

pub const Stats = struct { relisted: usize = 0, rescanned: usize = 0, dropped: usize = 0, before: usize = 0, after: usize = 0 };

/// Merge the `dirty` directories into the entries of `old_index`, appending the
/// result to `out`. Strings in `out` borrow from `old_index` and `strings`; keep
/// both alive until `writeIndex` returns. `error.TooManyChanges` means a full
/// walk is the cheaper option; `error.ScanIncomplete` means the listing raced
/// the filesystem — both are answered by the caller with a full scan.
pub fn merge(
    allocator: std.mem.Allocator,
    strings: std.mem.Allocator,
    old_index: []const u8,
    dirty: []const []const u8,
    root: []const u8,
    support_dir: []const u8,
    out: *std.ArrayList(format.IndexEntry),
) !Stats {
    const io = runtime.io;
    var reader = try reader_mod.IndexReader.init(allocator, old_index);
    defer reader.deinit();
    // ponytail: prefix checks below are linear in changed dirs; past this many a full walk is cheaper anyway.
    if (dirty.len > @max(64, reader.dirCount() / 20)) return error.TooManyChanges;
    var stats = Stats{ .before = @intCast(reader.numEntries()) };

    // 1. Each dirty dir is either relisted (still a directory) or gone (drop its subtree).
    var relist = std.StringHashMapUnmanaged(i64){}; // path → its own mtime
    defer relist.deinit(allocator);
    var drop_prefix: std.ArrayList([]const u8) = .empty;
    defer drop_prefix.deinit(allocator);
    for (dirty) |d| {
        if (config.shouldExcludeDescendant(d, root, support_dir)) continue;
        const st = std.Io.Dir.cwd().statFile(io, d, .{}) catch {
            try drop_prefix.append(allocator, d);
            continue;
        };
        if (st.kind != .directory) {
            try drop_prefix.append(allocator, d);
            continue;
        }
        try relist.put(allocator, d, st.mtime.toSeconds());
    }
    stats.relisted = relist.count();

    // 2. One getattrlistbulk pass per relisted dir → fresh direct children.
    var fresh: std.ArrayList(format.IndexEntry) = .empty;
    defer fresh.deinit(allocator);
    const Range = struct { start: usize, end: usize, emitted: bool = false };
    var fresh_range = std.StringHashMapUnmanaged(Range){}; // relisted dir → its slice of `fresh`
    defer fresh_range.deinit(allocator);
    var new_children = std.StringHashMapUnmanaged(void){}; // full paths of dir children in fresh listings
    defer new_children.deinit(allocator);
    var it = relist.keyIterator();
    while (it.next()) |d| {
        var tsv = std.Io.Writer.Allocating.init(allocator);
        defer tsv.deinit();
        if (!try bulk_scan.listDir(allocator, d.*, root, support_dir, &tsv.writer)) return error.ScanIncomplete;
        var fixed = std.Io.Reader.fixed(tsv.writer.buffered());
        const start = fresh.items.len;
        try builder.parseScanReader(allocator, strings, &fixed, &fresh);
        try fresh_range.put(allocator, d.*, .{ .start = start, .end = fresh.items.len });
        for (fresh.items[start..]) |e| {
            if (e.kind == .directory) try new_children.put(allocator, try joinAlloc(strings, e.dir_path, e.name), {});
        }
    }

    // 3. Keep old entries outside relisted dirs; a relisted dir's fresh listing
    //    takes the place of its first old entry so directory ids keep their
    //    order (the sidebar's ext-breakdown seek is linear in dir id). Remember
    //    old dir children of relisted dirs so renamed/deleted subtrees drop and
    //    new ones get scanned.
    var old_children = std.StringHashMapUnmanaged(void){};
    defer old_children.deinit(allocator);
    var path_buf: [std.fs.max_path_bytes + 256]u8 = undefined;
    const n: u32 = @intCast(reader.numEntries());
    try out.ensureUnusedCapacity(allocator, n);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const meta = reader.getMeta(i) orelse return error.CorruptIndex;
        var entry = format.IndexEntry{
            .name = reader.getName(i) orelse return error.CorruptIndex,
            .dir_path = reader.getDirPath(i) orelse return error.CorruptIndex,
            .size = meta.size,
            .mtime = meta.mtime,
            .kind = meta.kind,
            .category = meta.category,
        };
        if (fresh_range.getPtr(entry.dir_path)) |range| {
            if (entry.kind == .directory) {
                const full = joinBuf(&path_buf, entry.dir_path, entry.name) orelse return error.CorruptIndex;
                try old_children.put(allocator, try strings.dupe(u8, full), {});
            }
            if (!range.emitted) {
                range.emitted = true;
                try out.appendSlice(allocator, fresh.items[range.start..range.end]);
            }
            continue;
        }
        if (entry.kind == .directory) {
            // A dir's own mtime moves with its contents, but FSEvents reports
            // the dir, not its parent, so the entry in the parent's listing is stale.
            const full = joinBuf(&path_buf, entry.dir_path, entry.name) orelse return error.CorruptIndex;
            if (relist.get(full)) |mtime| entry.mtime = mtime;
        }
        try out.append(allocator, entry);
    }
    // Relisted dirs the old index had no entries for (e.g. a dir created and
    // filled inside one batch whose parent event was coalesced away).
    var range_it = fresh_range.valueIterator();
    while (range_it.next()) |range| if (!range.emitted) try out.appendSlice(allocator, fresh.items[range.start..range.end]);

    // 4. Old dir children missing from the fresh listing are gone (deleted or
    //    renamed away) → drop the subtree. Fresh dir children the old index
    //    never saw (created or renamed in) → recursive scan.
    var scan_roots: std.ArrayList([]const u8) = .empty;
    defer scan_roots.deinit(allocator);
    var old_it = old_children.keyIterator();
    while (old_it.next()) |p| if (!new_children.contains(p.*)) try drop_prefix.append(allocator, p.*);
    var new_it = new_children.keyIterator();
    while (new_it.next()) |p| if (!old_children.contains(p.*)) try scan_roots.append(allocator, p.*);
    if (drop_prefix.items.len + scan_roots.items.len > 256) return error.TooManyChanges;

    // Vanished subtrees go; so do relisted dirs inside a new subtree, which
    // the recursive scan below covers.
    if (drop_prefix.items.len + scan_roots.items.len > 0) {
        var w: usize = 0;
        for (out.items) |e| {
            if (underAny(e.dir_path, drop_prefix.items) or underAny(e.dir_path, scan_roots.items)) continue;
            out.items[w] = e;
            w += 1;
        }
        stats.dropped = out.items.len - w;
        out.shrinkRetainingCapacity(w);
    }
    for (scan_roots.items) |r| {
        var nested = false;
        for (scan_roots.items) |other| nested = nested or (other.len < r.len and core_paths.isPathUnder(r, other));
        if (nested) continue;
        builder.scanSubtree(allocator, strings, r, support_dir, out) catch |err| switch (err) {
            // Temp dirs vanish between listing and scan; the parent's next
            // event retires the dangling entry. Anything else is a real failure.
            error.ScanIncomplete => {
                _ = std.Io.Dir.cwd().statFile(io, r, .{}) catch continue;
                return err;
            },
            else => return err,
        };
        stats.rescanned += 1;
    }
    stats.after = out.items.len;
    return stats;
}

fn underAny(path: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| if (core_paths.isPathUnder(path, p)) return true;
    return false;
}

fn joinBuf(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), name }) catch null;
}

fn joinAlloc(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, dir, "/"), name });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Sorted "dir/name\tsize\tmtime\tkind\tcat" lines from an index, so two
/// indexes compare by content regardless of shard/thread order.
fn snapshot(allocator: std.mem.Allocator, index: []const u8) ![]u8 {
    var reader = try reader_mod.IndexReader.init(allocator, index);
    defer reader.deinit();
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit(allocator);
    }
    var i: u32 = 0;
    while (i < reader.numEntries()) : (i += 1) {
        const m = reader.getMeta(i).?;
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}\t{d}\t{d}\t{t}\t{t}", .{
            reader.getDirPath(i).?, reader.getName(i).?, m.size, m.mtime, m.kind, m.category,
        }));
    }
    std.mem.sort([]u8, lines.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var joined: std.ArrayList(u8) = .empty;
    errdefer joined.deinit(allocator);
    for (lines.items) |l| {
        try joined.appendSlice(allocator, l);
        try joined.append(allocator, '\n');
    }
    return joined.toOwnedSlice(allocator);
}

fn fullIndex(allocator: std.mem.Allocator, root: []const u8, support: []const u8) ![]u8 {
    var strings = std.heap.ArenaAllocator.init(allocator);
    defer strings.deinit();
    var entries: std.ArrayList(format.IndexEntry) = .empty;
    defer entries.deinit(allocator);
    try builder.scanSubtree(allocator, strings.allocator(), root, support, &entries);
    return format.writeIndex(allocator, entries.items);
}

test "incremental merge matches a fresh full scan after create, delete, rename, nest, and remove" {
    const allocator = std.testing.allocator;
    const io = runtime.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "support");
    for ([_][]const u8{ "data/a/sub", "data/b", "data/del" }) |d| try tmp.dir.createDirPath(io, d);
    for ([_][]const u8{ "data/keep.txt", "data/gone.txt", "data/a/x.txt", "data/a/sub/z.md", "data/b/w.txt", "data/del/d.txt" }) |f|
        try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "content" });
    const root = try tmp.dir.realPathFileAlloc(io, "data", allocator);
    defer allocator.free(root);
    const support = try tmp.dir.realPathFileAlloc(io, "support", allocator);
    defer allocator.free(support);

    const old = try fullIndex(allocator, root, support);
    defer allocator.free(old);

    // Mutations, each the kind FSEvents reports as its containing directory.
    try tmp.dir.writeFile(io, .{ .sub_path = "data/new.txt", .data = "new" });
    try tmp.dir.deleteFile(io, "data/gone.txt");
    try tmp.dir.rename("data/a", tmp.dir, "data/a2", io);
    try tmp.dir.createDirPath(io, "data/n/deep");
    try tmp.dir.writeFile(io, .{ .sub_path = "data/n/deep/leaf.txt", .data = "leaf" });
    try tmp.dir.writeFile(io, .{ .sub_path = "data/b/more.txt", .data = "more" });
    try tmp.dir.deleteTree(io, "data/del");

    const dirty = [_][]const u8{
        root,
        try std.fs.path.join(allocator, &.{ root, "n" }),
        try std.fs.path.join(allocator, &.{ root, "n/deep" }),
        try std.fs.path.join(allocator, &.{ root, "b" }),
        try std.fs.path.join(allocator, &.{ root, "del" }),
    };
    defer for (dirty[1..]) |d| allocator.free(d);

    var strings = std.heap.ArenaAllocator.init(allocator);
    defer strings.deinit();
    var merged: std.ArrayList(format.IndexEntry) = .empty;
    defer merged.deinit(allocator);
    const stats = try merge(allocator, strings.allocator(), old, &dirty, root, support, &merged);
    try std.testing.expectEqual(@as(usize, 4), stats.relisted); // del is gone
    try std.testing.expectEqual(@as(usize, 2), stats.rescanned); // a2, n (n/deep nested)
    const merged_index = try format.writeIndex(allocator, merged.items);
    defer allocator.free(merged_index);

    const fresh = try fullIndex(allocator, root, support);
    defer allocator.free(fresh);
    const want = try snapshot(allocator, fresh);
    defer allocator.free(want);
    const got = try snapshot(allocator, merged_index);
    defer allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expect(std.mem.indexOf(u8, got, "/a2/sub/z.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "gone.txt") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "/del/") == null);

    // An empty dirty set reproduces the old index exactly.
    var same: std.ArrayList(format.IndexEntry) = .empty;
    defer same.deinit(allocator);
    _ = try merge(allocator, strings.allocator(), old, &.{}, root, support, &same);
    const same_index = try format.writeIndex(allocator, same.items);
    defer allocator.free(same_index);
    const old_snap = try snapshot(allocator, old);
    defer allocator.free(old_snap);
    const same_snap = try snapshot(allocator, same_index);
    defer allocator.free(same_snap);
    try std.testing.expectEqualStrings(old_snap, same_snap);
}
