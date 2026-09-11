const std = @import("std");
const cli = @import("core/cli.zig");
const filters = @import("core/filters.zig");
const humanize = @import("core/humanize.zig");
const runtime = @import("core/runtime.zig");
const types = @import("core/types.zig");
const reader_mod = @import("index/reader.zig");
const search = @import("index/search.zig");

extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;

const Config = struct {
    query: []const u8 = "",
    index_path: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    max_depth: u32 = 1,
    limit: usize = 50,
    scan_limit: u32 = 100_000,
    sort_column: search.SortColumn = .size,
    ascending: bool = false,
    human_sizes: bool = true,
    show_header: bool = true,
};

const MappedIndex = struct {
    bytes: []const u8,

    fn openFile(allocator: std.mem.Allocator, path: []const u8) !MappedIndex {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        const fd = open(path_z.ptr, 0); // O_RDONLY
        if (fd < 0) return error.OpenIndexFailed;
        defer _ = close(fd);

        const file_size = lseek(fd, 0, 2); // SEEK_END
        if (file_size <= 0) return error.EmptyIndex;
        const len: usize = @intCast(file_size);
        const raw = mmap(null, len, 1, 2, fd, 0) orelse return error.MapIndexFailed; // PROT_READ, MAP_PRIVATE
        if (@intFromPtr(raw) == std.math.maxInt(usize)) return error.MapIndexFailed;

        return .{ .bytes = @as([*]const u8, @ptrCast(raw))[0..len] };
    }

    fn deinit(self: MappedIndex) void {
        _ = munmap(@ptrCast(@constCast(self.bytes.ptr)), self.bytes.len);
    }
};

pub fn main(init: std.process.Init) !void {
    runtime.init(init);
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (cli.handleCommon(args, "zest-query", usage)) return;
    const config = parseArgs(args) catch |err| cli.fail("zest-query", "invalid arguments ({t})", .{err});

    const needs_home = config.index_path == null or config.scope == null;
    const home_owned = if (needs_home)
        runtime.getEnvVarOwned(allocator, "HOME") catch {
            std.debug.print("error: HOME is not set; pass --index and --scope explicitly\n", .{});
            std.process.exit(2);
        }
    else
        null;
    defer if (home_owned) |home| allocator.free(home);
    const home = home_owned orelse "";

    const index_path_owned = if (config.index_path == null)
        try std.fmt.allocPrint(allocator, "{s}/Library/Application Support/zest/index.zst", .{home})
    else
        null;
    defer if (index_path_owned) |path| allocator.free(path);

    const index_path = config.index_path orelse index_path_owned.?;
    const scope = config.scope orelse home;

    const mapped = MappedIndex.openFile(allocator, index_path) catch |err| {
        std.debug.print("error: cannot open index {s} ({t})\n", .{ index_path, err });
        std.process.exit(1);
    };
    defer mapped.deinit();

    var reader = reader_mod.IndexReader.init(allocator, mapped.bytes) catch |err| {
        std.debug.print("error: invalid index {s} ({t})\n", .{ index_path, err });
        std.process.exit(1);
    };
    defer reader.deinit();

    var parsed = try filters.parse(allocator, config.query, runtime.unixTimestamp());
    defer parsed.deinit();

    const rows = try search.search(allocator, &reader, .{
        .query = parsed.text,
        .filters = parsed.filters_list,
        .max_results = config.scan_limit,
        .scope = scope,
        .max_depth = config.max_depth,
    });
    defer allocator.free(rows);

    search.sortResults(rows, config.sort_column, config.ascending, false);
    try printRows(rows[0..@min(rows.len, config.limit)], config);
}

fn parseArgs(args: []const []const u8) !Config {
    var config: Config = .{};
    var has_query = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--index")) {
            i += 1;
            if (i >= args.len) return error.MissingIndexPath;
            config.index_path = args[i];
        } else if (std.mem.eql(u8, arg, "--scope")) {
            i += 1;
            if (i >= args.len) return error.MissingScope;
            config.scope = args[i];
        } else if (std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i >= args.len) return error.MissingDepth;
            config.max_depth = if (std.mem.eql(u8, args[i], "all"))
                std.math.maxInt(u32)
            else
                try std.fmt.parseInt(u32, args[i], 10);
            if (config.max_depth == 0) return error.InvalidDepth;
        } else if (std.mem.eql(u8, arg, "--limit")) {
            i += 1;
            if (i >= args.len) return error.MissingLimit;
            config.limit = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--scan-limit")) {
            i += 1;
            if (i >= args.len) return error.MissingScanLimit;
            config.scan_limit = try std.fmt.parseInt(u32, args[i], 10);
            if (config.scan_limit == 0) return error.InvalidScanLimit;
        } else if (std.mem.eql(u8, arg, "--sort")) {
            i += 1;
            if (i >= args.len) return error.MissingSort;
            config.sort_column = parseSort(args[i]) orelse return error.InvalidSort;
        } else if (std.mem.eql(u8, arg, "--asc")) {
            config.ascending = true;
        } else if (std.mem.eql(u8, arg, "--desc")) {
            config.ascending = false;
        } else if (std.mem.eql(u8, arg, "--bytes")) {
            config.human_sizes = false;
        } else if (std.mem.eql(u8, arg, "--no-header")) {
            config.show_header = false;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else if (!has_query) {
            config.query = arg;
            has_query = true;
        } else {
            return error.MultipleQueries;
        }
    }

    if (config.limit > config.scan_limit) return error.LimitExceedsScanLimit;
    return config;
}

fn parseSort(value: []const u8) ?search.SortColumn {
    if (std.mem.eql(u8, value, "name")) return .name;
    if (std.mem.eql(u8, value, "size")) return .size;
    if (std.mem.eql(u8, value, "mtime") or std.mem.eql(u8, value, "date")) return .mtime;
    if (std.mem.eql(u8, value, "type") or std.mem.eql(u8, value, "category")) return .category;
    return null;
}

fn printRows(rows: []const search.SearchResult, config: Config) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(runtime.io, &buffer);
    const out = &file_writer.interface;

    if (config.show_header) try out.print("SIZE\tMTIME\tKIND\tPATH\n", .{});
    for (rows) |row| {
        var size_buf: [24]u8 = undefined;
        const size = if (config.human_sizes)
            humanize.bytes(&size_buf, row.size)
        else
            std.fmt.bufPrint(&size_buf, "{d}", .{row.size}) catch "?";
        try out.print("{s}\t{d}\t{s}\t", .{ size, row.mtime, kindName(row.kind) });
        if (std.mem.eql(u8, row.dir_path, "/")) {
            try out.print("/{s}\n", .{row.name});
        } else {
            try out.print("{s}/{s}\n", .{ row.dir_path, row.name });
        }
    }
    try out.flush();
}

fn kindName(kind: types.FileKind) []const u8 {
    return switch (kind) {
        .file => "file",
        .directory => "directory",
        .symlink => "symlink",
    };
}

const usage =
    \\Usage: zest-query [QUERY] [OPTIONS]
    \\
    \\Read the existing Zest index without touching the filesystem.
    \\QUERY accepts the same text and qualifiers as the app, such as
    \\'size:>1gb kind:file' or 'date:week'.
    \\
    \\Options:
    \\  --index PATH       Index file (default: Zest index under $HOME)
    \\  --scope PATH       Absolute search root (default: $HOME)
    \\  --depth N|all      Scope depth (default: 1, direct children)
    \\  --limit N          Rows to print (default: 50)
    \\  --scan-limit N     Matching rows collected before sort (default: 100000)
    \\  --sort COLUMN      name, size, mtime/date, type/category (default: size)
    \\  --asc | --desc     Sort direction (default: descending)
    \\  --bytes            Print exact byte counts instead of human sizes
    \\  --no-header        Omit the TSV header
    \\  -h, --help         Show this help
    \\  -V, --version      Print version
    \\
    \\Examples:
    \\  zest-query --scope "$HOME" --depth 1 --sort size --desc
    \\  zest-query 'size:>1gb kind:file' --depth all --sort size --desc
    \\  zest-query 'date:week size:>100mb' --depth all --sort mtime --desc
    \\
;

test "parse query options" {
    const args = [_][]const u8{
        "zest-query", "size:>1gb", "--scope",      "/Users/test", "--depth", "all",
        "--limit",    "25",        "--scan-limit", "200",         "--sort",  "mtime",
        "--asc",      "--bytes",   "--no-header",
    };
    const config = try parseArgs(&args);
    try std.testing.expectEqualStrings("size:>1gb", config.query);
    try std.testing.expectEqualStrings("/Users/test", config.scope.?);
    try std.testing.expectEqual(std.math.maxInt(u32), config.max_depth);
    try std.testing.expectEqual(@as(usize, 25), config.limit);
    try std.testing.expectEqual(@as(u32, 200), config.scan_limit);
    try std.testing.expectEqual(search.SortColumn.mtime, config.sort_column);
    try std.testing.expect(config.ascending);
    try std.testing.expect(!config.human_sizes);
    try std.testing.expect(!config.show_header);
}

test "parse defaults support a bounded home listing" {
    const args = [_][]const u8{"zest-query"};
    const config = try parseArgs(&args);
    try std.testing.expectEqual(@as(u32, 1), config.max_depth);
    try std.testing.expectEqual(@as(usize, 50), config.limit);
    try std.testing.expectEqual(search.SortColumn.size, config.sort_column);
    try std.testing.expect(!config.ascending);
}

test "printed limit cannot exceed scan limit" {
    const args = [_][]const u8{ "zest-query", "--limit", "11", "--scan-limit", "10" };
    try std.testing.expectError(error.LimitExceedsScanLimit, parseArgs(&args));
}
