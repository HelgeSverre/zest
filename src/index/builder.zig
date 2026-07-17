const std = @import("std");
const types = @import("../core/types.zig");
const format = @import("format.zig");
const config = @import("../config/config.zig");
const runtime = @import("../core/runtime.zig");
const bulk_scan = @import("bulk_scan.zig");
const humanize = @import("../core/humanize.zig");

/// Build the index: walk the filesystem in parallel (a `getattrlistbulk` worker
/// pool, see `bulk_scan.zig`), streaming entries to per-worker temp files, then
/// read them back and convert to the columnar index format. The temp files
/// survive a crash mid-walk.
pub fn buildIndex(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const support_dir = try config.appSupportDir(allocator);
    defer allocator.free(support_dir);

    const n_threads = @min(std.Thread.getCpuCount() catch 4, bulk_scan.max_scan_threads);

    // Phase 1: parallel walk → per-worker scan.tmp.N files.
    const t_start = runtime.nowNanos();
    var entry_count: u64 = 0;
    const scan_paths = try bulk_scan.parallelScan(allocator, root, support_dir, n_threads, &entry_count);
    defer {
        for (scan_paths) |p| {
            std.Io.Dir.deleteFileAbsolute(runtime.io, p) catch {};
            allocator.free(p);
        }
        allocator.free(scan_paths);
    }
    const t_walked = runtime.nowNanos();

    // Phase 2: read the temp files back, build the columnar index.
    std.debug.print("  building columnar index...\n", .{});
    var parsed: usize = 0;
    const index_data = try buildFromScanFiles(allocator, scan_paths, &parsed);
    errdefer allocator.free(index_data);
    try validateParsedCount(entry_count, parsed);
    const t_built = runtime.nowNanos();

    var walk_buf: [16]u8 = undefined;
    var build_buf: [16]u8 = undefined;
    var count_buf: [32]u8 = undefined;
    std.debug.print("  timing: walk={s} build={s} ({s} files, {d} threads)\n", .{
        humanize.duration(&walk_buf, @divTrunc(t_walked - t_start, std.time.ns_per_ms)),
        humanize.duration(&build_buf, @divTrunc(t_built - t_walked, std.time.ns_per_ms)),
        humanize.count(&count_buf, entry_count),
        n_threads,
    });

    return index_data;
}

/// Read one or more TSV scan files and build the columnar index from all of
/// them. Entry order across files is irrelevant — the columnar format reindexes.
fn buildFromScanFiles(allocator: std.mem.Allocator, scan_paths: []const []u8, parsed_out: ?*usize) ![]u8 {
    var entries: std.ArrayList(format.IndexEntry) = .empty;
    defer entries.deinit(allocator);

    var owned_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_strings.items) |s| allocator.free(s);
        owned_strings.deinit(allocator);
    }

    for (scan_paths) |scan_path| {
        const file = std.Io.Dir.openFileAbsolute(runtime.io, scan_path, .{}) catch |err| {
            // Keep building from the remaining shards, but say so — a silent
            // skip here once turned a 4.1M-entry walk into an empty index.
            std.debug.print("warning: cannot re-open scan shard {s}: {}\n", .{ scan_path, err });
            continue;
        };
        defer file.close(runtime.io);
        // Worst-case escaped record: name ≤ 255*2 + path ≤ 4096*2 + numeric
        // fields — just under 9KB. 16KB gives comfortable headroom so a
        // backslash-heavy path can't abort the build with StreamTooLong.
        var line_buf: [16384]u8 = undefined;
        var file_reader = file.reader(runtime.io, &line_buf);
        try parseScanReader(allocator, &file_reader.interface, &entries, &owned_strings);
    }

    if (parsed_out) |p| p.* = entries.items.len;
    return format.writeIndex(allocator, entries.items);
}

/// Parse tab-separated scan lines from `reader`, appending entries (and their
/// owned name/dir_path strings) to the given lists. Uses `takeDelimiter`, which
/// *consumes* the newline — `takeDelimiterExclusive` leaves it in place and turns
/// blank lines into a non-advancing infinite loop.
fn parseScanReader(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    entries: *std.ArrayList(format.IndexEntry),
    owned_strings: *std.ArrayList([]u8),
) !void {
    while (try reader.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;

        // Parse tab-separated: name \t dir_path \t size \t mtime \t kind \t category
        var fields: [6][]const u8 = undefined;
        var field_idx: usize = 0;
        var start: usize = 0;
        for (line, 0..) |ch, i| {
            if (ch == '\t') {
                if (field_idx < 6) {
                    fields[field_idx] = line[start..i];
                    field_idx += 1;
                }
                start = i + 1;
            }
        }
        if (field_idx < 6 and start <= line.len) {
            fields[field_idx] = line[start..];
            field_idx += 1;
        }
        if (field_idx < 6) continue; // malformed line

        // Unescape tab/newline/backslash that were escaped by the scanner.
        // unescapeTsv writes into a buffer <= s.len, so dupe-sized allocations are exact.
        const name_raw = fields[0];
        const dir_raw = fields[1];
        const name_buf = try allocator.alloc(u8, name_raw.len);
        try owned_strings.append(allocator, name_buf);
        const name = format.unescapeTsv(name_buf, name_raw);
        const dir_buf = try allocator.alloc(u8, dir_raw.len);
        try owned_strings.append(allocator, dir_buf);
        const dir_path = format.unescapeTsv(dir_buf, dir_raw);

        try entries.append(allocator, .{
            .name = name,
            .dir_path = dir_path,
            .size = std.fmt.parseInt(u64, fields[2], 10) catch 0,
            .mtime = std.fmt.parseInt(i64, fields[3], 10) catch 0,
            .kind = std.enums.fromInt(types.FileKind, std.fmt.parseInt(u8, fields[4], 10) catch 0) orelse .file,
            .category = std.enums.fromInt(types.FileCategory, std.fmt.parseInt(u8, fields[5], 10) catch 0) orelse .uncategorized,
        });
    }
}

/// Refuse to publish an index that lost the entire scan: the walk counted
/// entries but the parse phase read none back (unreadable/vanished shard
/// files). Publishing would atomically replace a good index with an empty
/// one — observed once when all 8 shard re-opens failed silently.
fn validateParsedCount(walked: u64, parsed: usize) !void {
    if (walked > 0 and parsed == 0) return error.ScanParseLostAllEntries;
}

test "validateParsedCount rejects a zero-entry parse of a non-empty walk" {
    try std.testing.expectError(error.ScanParseLostAllEntries, validateParsedCount(4_110_431, 0));
    try validateParsedCount(0, 0); // genuinely empty tree is fine
    try validateParsedCount(17, 17);
    try validateParsedCount(17, 12); // partial loss still publishes (warned elsewhere)
}

/// Test helper: build an index from a single in-memory scan reader.
fn buildFromScanReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    var entries: std.ArrayList(format.IndexEntry) = .empty;
    defer entries.deinit(allocator);
    var owned_strings: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_strings.items) |s| allocator.free(s);
        owned_strings.deinit(allocator);
    }
    try parseScanReader(allocator, reader, &entries, &owned_strings);
    return format.writeIndex(allocator, entries.items);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const reader_mod = @import("reader.zig");

test "buildFromScanReader parses entries and skips blank lines without hanging" {
    const allocator = std.testing.allocator;
    // Two valid entries separated by a blank line. The blank line is the exact
    // input that made the old `takeDelimiterExclusive` loop spin forever:
    // it returned an empty slice without consuming the '\n'. If this test
    // terminates at all, the regression is fixed.
    const data =
        "a.txt\t/x\t10\t100\t0\t1\n" ++
        "\n" ++
        "b.txt\t/y\t20\t200\t0\t1\n";

    var reader = std.Io.Reader.fixed(data);
    const index_data = try buildFromScanReader(allocator, &reader);
    defer allocator.free(index_data);

    var idx_reader = try reader_mod.IndexReader.init(allocator, index_data);
    defer idx_reader.deinit();

    try std.testing.expectEqual(@as(u64, 2), idx_reader.numEntries());
    try std.testing.expectEqualStrings("a.txt", idx_reader.getName(0).?);
    try std.testing.expectEqualStrings("b.txt", idx_reader.getName(1).?);
}

test "buildFromScanReader handles a final line without a trailing newline" {
    const allocator = std.testing.allocator;
    const data = "only.txt\t/z\t5\t50\t0\t1"; // no trailing '\n'

    var reader = std.Io.Reader.fixed(data);
    const index_data = try buildFromScanReader(allocator, &reader);
    defer allocator.free(index_data);

    var idx_reader = try reader_mod.IndexReader.init(allocator, index_data);
    defer idx_reader.deinit();

    try std.testing.expectEqual(@as(u64, 1), idx_reader.numEntries());
    try std.testing.expectEqualStrings("only.txt", idx_reader.getName(0).?);
}

test "parseScanReader round-trips filenames containing tab, newline, and backslash" {
    // Simulates what bulk_scan would write after escapeTsv:
    // name "we\tird\nna\\me" at dir "/pa\\th" → escaped → TSV line → unescape → original.
    const allocator = std.testing.allocator;
    const original_name = "we\tird\nna\\me";
    const original_path = "/pa\\th";

    // Manually escape to build the TSV line (same logic as bulk_scan uses).
    var esc_name_buf: [64]u8 = undefined;
    var esc_path_buf: [64]u8 = undefined;
    const esc_name = format.escapeTsv(&esc_name_buf, original_name).?;
    const esc_path = format.escapeTsv(&esc_path_buf, original_path).?;

    // Build TSV line: <esc_name>\t<esc_path>\t0\t0\t0\t2
    var line_buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "{s}\t{s}\t0\t0\t0\t2\n", .{ esc_name, esc_path });

    var reader = std.Io.Reader.fixed(line);
    const index_data = try buildFromScanReader(allocator, &reader);
    defer allocator.free(index_data);

    var idx_reader = try reader_mod.IndexReader.init(allocator, index_data);
    defer idx_reader.deinit();

    try std.testing.expectEqual(@as(u64, 1), idx_reader.numEntries());
    try std.testing.expectEqualStrings(original_name, idx_reader.getName(0).?);
    try std.testing.expectEqualStrings(original_path, idx_reader.getDirPath(0).?);
}
