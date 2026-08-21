//! Programmatic benchmark of the exact C-ABI surface the Swift app calls.
//! No UI, no AppleScript — mmaps the real index and times zest_query /
//! zest_histogram / zest_ext_breakdown the same way ZestCore.swift invokes
//! them, including a "drain" pass that touches every returned row (the FFI
//! transfer cost Swift pays before String allocation even starts).
//!
//! Build (lib variant under test must be built first):
//!   zig build core -Doptimize=ReleaseFast
//!   zig build-exe benchmarks/bench_capi.zig zig-out/lib/libzest-core.a -lc -OReleaseFast -femit-bin=zig-out/bin/bench-capi
//! Run:
//!   BENCH_QUICK=1 ./zig-out/bin/bench-capi  (BENCH_INDEX overrides index path)
const std = @import("std");

// --- C ABI mirror (matches src/capi/zest_core.zig) ---
const Core = opaque {};
const Query = opaque {};

const ZestStr = extern struct { ptr: [*]const u8, len: usize };
const ZestRow = extern struct {
    name: ZestStr,
    dir_path: ZestStr,
    size: u64,
    mtime: i64,
    kind: u8,
    category: u8,
};
const ZestHistogram = extern struct { counts: [9]u32 };
const ZestExtCount = extern struct { name: [16]u8, count: u32 };

extern fn zest_open(index_bytes: [*]const u8, len: usize) ?*Core;
extern fn zest_close(core: *Core) void;
extern fn zest_count(core: *Core) usize;
extern fn zest_query(core: *Core, q: [*:0]const u8, scope: [*:0]const u8, max_depth: u32, max_results: u32) ?*Query;
extern fn zest_query_count(q: *const Query) usize;
extern fn zest_query_row(q: *const Query, i: usize) ZestRow;
extern fn zest_query_free(q: *Query) void;
extern fn zest_histogram(core: *Core, scope: [*:0]const u8, max_depth: u32) ZestHistogram;
extern fn zest_ext_breakdown(core: *Core, scope: [*:0]const u8, max_depth: u32, cat: u8, max: u32, out: [*]ZestExtCount) u32;

// Raw libc (Zig 0.16 std.fs/std.posix require an Io handle; this is simpler).
extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;
extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, offset: i64) ?*anyopaque;
extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
extern "c" fn clock_gettime_nsec_np(clock_id: c_int) u64;
extern "c" fn getrusage(who: c_int, usage: *[18]i64) c_int;

/// Minimal monotonic timer over libc (std.time.Timer needs an Io handle in 0.16).
const Timer = struct {
    start_ns: u64,
    fn start() Timer {
        return .{ .start_ns = clock_gettime_nsec_np(6) }; // CLOCK_MONOTONIC
    }
    fn reset(self: *Timer) void {
        self.start_ns = clock_gettime_nsec_np(6);
    }
    fn read(self: *Timer) u64 {
        return clock_gettime_nsec_np(6) - self.start_ns;
    }
};
const c_open = open;
const c_close = close;
const c_lseek = lseek;
const c_mmap = mmap;
const c_munmap = munmap;

const alloc = std.heap.c_allocator;

const Stats = struct {
    n: usize,
    median_ns: u64,
    min_ns: u64,
    max_ns: u64,
};

fn summarize(samples: []u64) Stats {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{
        .n = samples.len,
        .median_ns = samples[samples.len / 2],
        .min_ns = samples[0],
        .max_ns = samples[samples.len - 1],
    };
}

fn fmtMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

/// Run one query config repeatedly. Adaptive: 1 warmup; if the warmup alone
/// exceeds 5s, report it as the single sample (don't melt the machine);
/// otherwise collect `max_samples` timed runs. Returns (stats, result_count,
/// drain_ns) where drain is one pass of zest_query_row over every row,
/// summing name bytes so the access can't be optimized away.
fn benchQuery(
    core: *Core,
    query: [:0]const u8,
    scope: [:0]const u8,
    max_depth: u32,
    max_results: u32,
    max_samples: usize,
) !struct { stats: Stats, count: usize, drain_ns: u64 } {
    var timer = Timer.start();

    // Warmup (also gives us the result handle for the drain measurement).
    timer.reset();
    var q = zest_query(core, query.ptr, scope.ptr, max_depth, max_results) orelse return error.QueryFailed;
    const warmup_ns = timer.read();
    const count = zest_query_count(q);

    // Drain: touch every row once (the FFI transfer floor, pre-Swift-String).
    timer.reset();
    var checksum: u64 = 0;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const row = zest_query_row(q, i);
        checksum +%= row.name.len + row.dir_path.len + row.size;
        if (row.name.len > 0) checksum +%= row.name.ptr[0];
    }
    const drain_ns = timer.read();
    std.mem.doNotOptimizeAway(&checksum);
    zest_query_free(q);

    var samples: std.ArrayList(u64) = .empty;
    defer samples.deinit(alloc);
    try samples.append(alloc, warmup_ns);

    if (warmup_ns < 5_000_000_000) {
        var s: usize = 1;
        while (s < max_samples) : (s += 1) {
            timer.reset();
            q = zest_query(core, query.ptr, scope.ptr, max_depth, max_results) orelse return error.QueryFailed;
            try samples.append(alloc, timer.read());
            zest_query_free(q);
        }
    }

    return .{ .stats = summarize(samples.items), .count = count, .drain_ns = drain_ns };
}

fn maxRssMb() f64 {
    // raw getrusage: two 16-byte timevals precede ru_maxrss -> i64 index 4.
    var ru: [18]i64 = @splat(0);
    _ = getrusage(0, &ru); // RUSAGE_SELF; macOS maxrss is in bytes
    return @as(f64, @floatFromInt(ru[4])) / (1024.0 * 1024.0);
}

pub fn main() !void {
    // Config via env (Zig 0.16 moved argv behind std.process.Init; libc getenv
    // is simpler here since we link libc anyway):
    //   BENCH_INDEX=/path/to/index.zst  BENCH_QUICK=1
    const index_path: ?[]const u8 = if (std.c.getenv("BENCH_INDEX")) |p| std.mem.span(p) else null;
    const quick = std.c.getenv("BENCH_QUICK") != null;

    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return error.NoHome;
    const default_path = try std.fmt.allocPrint(alloc, "{s}/Library/Application Support/zest/index.zst", .{home});
    const path = index_path orelse default_path;
    const max_samples: usize = if (quick) 2 else 7;

    // mmap the index exactly the way the Swift app does (raw libc — the Zig
    // 0.16 std.fs surface requires an Io handle this harness doesn't need).
    const path_z = try alloc.dupeZ(u8, path);
    const fd = c_open(path_z.ptr, 0); // O_RDONLY
    if (fd < 0) return error.OpenFailed;
    defer _ = c_close(fd);
    const size = c_lseek(fd, 0, 2); // SEEK_END
    if (size <= 0) return error.EmptyIndex;
    const len: usize = @intCast(size);
    const raw = c_mmap(null, len, 1, 2, fd, 0) orelse return error.MmapFailed; // PROT_READ, MAP_PRIVATE
    if (@intFromPtr(raw) == std.math.maxInt(usize)) return error.MmapFailed; // MAP_FAILED
    const mapped: [*]const u8 = @ptrCast(raw);
    defer _ = c_munmap(raw, len);

    var timer = Timer.start();
    const core = zest_open(mapped, len) orelse return error.BadIndex;
    defer zest_close(core);
    const open_ns = timer.read();

    std.debug.print("index: {s} ({d:.1} MB), entries: {d}, zest_open: {d:.1} ms, rss after open: {d:.0} MB\n\n", .{
        path,
        @as(f64, @floatFromInt(len)) / (1024.0 * 1024.0),
        zest_count(core),
        fmtMs(open_ns),
        maxRssMb(),
    });

    const home_z = try alloc.dupeZ(u8, home);
    const root_z: [:0]const u8 = "/";
    const depth_max = std.math.maxInt(u32);

    const QueryCfg = struct {
        label: []const u8,
        query: [:0]const u8,
        scope: [:0]const u8,
        depth: u32,
        max: u32,
    };

    // The keystroke ladder mirrors typing "invoice" in the app's search field
    // (scope=.subfolders → root=$HOME, depth=max), at an intentionally large
    // engine cap (100k) and the app's current UI cap (2k). Folder-listing
    // mirrors navigation (browse mode: empty query, depth=1).
    var configs: std.ArrayList(QueryCfg) = .empty;
    defer configs.deinit(alloc);

    const caps = [_]u32{ 100_000, 2_000 };
    const ladder = [_][:0]const u8{ "i", "in", "inv", "invo", "invoice" };
    for (caps) |cap| {
        for (ladder) |q| {
            try configs.append(alloc, .{ .label = "search $HOME subtree", .query = q, .scope = home_z, .depth = depth_max, .max = cap });
        }
    }
    try configs.append(alloc, .{ .label = "search / everywhere", .query = "i", .scope = root_z, .depth = depth_max, .max = 100_000 });
    try configs.append(alloc, .{ .label = "browse (folder listing)", .query = "", .scope = home_z, .depth = 1, .max = 100_000 });

    std.debug.print("| op | query | cap | results | median ms | min | max | n | drain ms |\n", .{});
    std.debug.print("|---|---|---|---|---|---|---|---|---|\n", .{});
    for (configs.items) |cfg| {
        const r = try benchQuery(core, cfg.query, cfg.scope, cfg.depth, cfg.max, max_samples);
        std.debug.print("| {s} | `{s}` | {d} | {d} | {d:.1} | {d:.1} | {d:.1} | {d} | {d:.1} |\n", .{
            cfg.label,                cfg.query,             cfg.max,               r.count,
            fmtMs(r.stats.median_ns), fmtMs(r.stats.min_ns), fmtMs(r.stats.max_ns), r.stats.n,
            fmtMs(r.drain_ns),
        });
    }

    // Sidebar path: histogram + 9 ext breakdowns, depth 1 and subtree.
    const depths = [_]struct { label: []const u8, d: u32 }{
        .{ .label = "depth=1", .d = 1 },
        .{ .label = "subtree", .d = depth_max },
    };
    std.debug.print("\n| sidebar op | scope | median ms | min | max | n |\n|---|---|---|---|---|---|\n", .{});
    for (depths) |dd| {
        var samples: std.ArrayList(u64) = .empty;
        defer samples.deinit(alloc);
        var s: usize = 0;
        while (s < max_samples) : (s += 1) {
            timer.reset();
            const h = zest_histogram(core, home_z.ptr, dd.d);
            std.mem.doNotOptimizeAway(&h);
            try samples.append(alloc, timer.read());
            if (samples.items[0] > 5_000_000_000) break;
        }
        const st = summarize(samples.items);
        std.debug.print("| histogram {s} | $HOME | {d:.1} | {d:.1} | {d:.1} | {d} |\n", .{ dd.label, fmtMs(st.median_ns), fmtMs(st.min_ns), fmtMs(st.max_ns), st.n });

        samples.clearRetainingCapacity();
        s = 0;
        while (s < max_samples) : (s += 1) {
            timer.reset();
            var cat: u8 = 0;
            var total: u32 = 0;
            while (cat < 9) : (cat += 1) {
                var ext_out: [32]ZestExtCount = undefined;
                total += zest_ext_breakdown(core, home_z.ptr, dd.d, cat, 32, &ext_out);
            }
            std.mem.doNotOptimizeAway(&total);
            try samples.append(alloc, timer.read());
            if (samples.items[0] > 5_000_000_000) break;
        }
        const st2 = summarize(samples.items);
        std.debug.print("| ext_breakdown x9 {s} | $HOME | {d:.1} | {d:.1} | {d:.1} | {d} |\n", .{ dd.label, fmtMs(st2.median_ns), fmtMs(st2.min_ns), fmtMs(st2.max_ns), st2.n });
    }

    std.debug.print("\npeak rss: {d:.0} MB\n", .{maxRssMb()});
}
