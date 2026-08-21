//! Synthetic engine benchmark — no real index required.
//!
//! `bench_capi.zig` measures the C ABI against the user's real `index.zst`,
//! which is the number that matters but only exists on a machine that has run
//! the daemon. This harness builds a deterministic in-memory corpus instead, so
//! engine changes (the substring scan, case folding, cancellation) can be
//! measured anywhere — CI, a Linux dev box, a fresh checkout — and compared
//! before/after with the same seed.
//!
//! Build & run: `just bench-search`, or by hand:
//!   zig build-exe -OReleaseFast --dep zest -Mroot=benchmarks/bench_search.zig \
//!       -OReleaseFast -Mzest=src/engine.zig -lc -femit-bin=zig-out/bin/bench-search
//!   ./zig-out/bin/bench-search
//! `-OReleaseFast` has to be repeated before *each* `-M`: a module without it
//! compiles as Debug, which quietly makes the engine ~10x slower and the
//! numbers meaningless.
//! Env: BENCH_ENTRIES (default 1000000), BENCH_SAMPLES (default 7).
const std = @import("std");
const builtin = @import("builtin");

const zest = @import("zest");
const format = zest.format;
const reader_mod = zest.reader;
const search_mod = zest.search;
const filters_mod = zest.filters;

const alloc = std.heap.c_allocator;

// --- timing (libc clock_gettime; std.time.Timer needs an Io handle in 0.16) ---

const timespec = extern struct { sec: i64, nsec: i64 };
extern "c" fn clock_gettime(clk_id: c_int, tp: *timespec) c_int;
const clock_monotonic: c_int = if (builtin.os.tag == .macos) 6 else 1;

fn nowNs() u64 {
    var ts: timespec = undefined;
    _ = clock_gettime(clock_monotonic, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn median(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

fn fmtMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

// --- corpus ---

const words = [_][]const u8{
    "report",   "invoice", "screenshot", "archive", "backup",  "photo",   "notes",
    "index",    "readme",  "config",     "draft",   "final",   "summary", "budget",
    "meeting",  "project", "sample",     "export",  "render",  "session", "capture",
    "document", "resume",  "contract",   "receipt", "profile", "avatar",  "banner",
    "Résumé",
    "Übersicht",
    "Ελλάδα",
    "Москва",
    "CAFÉ",
    "MÜNCHEN",
    "naïve",
};
const exts = [_][]const u8{
    "txt", "pdf", "png", "jpg", "zig", "swift", "md", "json", "zip", "mp4", "csv", "log",
};
const dir_words = [_][]const u8{
    "Documents", "Downloads", "Projects", "src", "assets", "node_modules", "build",
    "Pictures",  "Music",     "vendor",   "tmp", "docs",   "tests",        "Library",
};

/// Deterministic corpus: `n` entries spread over ~n/40 directories, with a
/// realistic mix of casing, extensions and a slice of non-ASCII names.
fn buildCorpus(n: usize) !struct { entries: []format.IndexEntry, strings: [][]u8 } {
    var prng = std.Random.DefaultPrng.init(0x5A455354);
    const rand = prng.random();

    const dir_count = @max(1, n / 40);
    const dirs = try alloc.alloc([]u8, dir_count);
    for (dirs, 0..) |*d, i| {
        const a = dir_words[rand.uintLessThan(usize, dir_words.len)];
        const b = dir_words[rand.uintLessThan(usize, dir_words.len)];
        d.* = try std.fmt.allocPrint(alloc, "/Users/bench/{s}/{s}/d{d}", .{ a, b, i });
    }

    const entries = try alloc.alloc(format.IndexEntry, n);
    const strings = try alloc.alloc([]u8, n);
    for (entries, 0..) |*e, i| {
        const w = words[rand.uintLessThan(usize, words.len)];
        const w2 = words[rand.uintLessThan(usize, words.len)];
        const ext = exts[rand.uintLessThan(usize, exts.len)];
        const name = switch (rand.uintLessThan(u8, 4)) {
            0 => try std.fmt.allocPrint(alloc, "{s}_{s}_{d}.{s}", .{ w, w2, i, ext }),
            1 => try std.fmt.allocPrint(alloc, "{s}-{d}.{s}", .{ w, i % 997, ext }),
            2 => try std.fmt.allocPrint(alloc, "{s}.{s}", .{ w, ext }),
            else => try std.fmt.allocPrint(alloc, "{s}{d}", .{ w, i }),
        };
        strings[i] = name;
        e.* = .{
            .name = name,
            .dir_path = dirs[rand.uintLessThan(usize, dir_count)],
            .size = rand.uintLessThan(u64, 64 * 1024 * 1024),
            .mtime = 1_700_000_000 + @as(i64, @intCast(i % 1_000_000)),
            .kind = if (i % 40 == 0) .directory else .file,
            .category = @enumFromInt(rand.uintLessThan(u8, 9)),
        };
    }
    return .{ .entries = entries, .strings = strings };
}

// --- bench ---

const Case = struct {
    label: []const u8,
    query: []const u8,
    scope: []const u8 = "/",
    max_depth: u32 = std.math.maxInt(u32),
    max_results: u32 = 100_000,
};

fn run(reader: *reader_mod.IndexReader, case: Case, samples: usize) !void {
    const times = try alloc.alloc(u64, samples);
    defer alloc.free(times);

    var count: usize = 0;
    for (times) |*t| {
        const start = nowNs();
        const results = try search_mod.search(alloc, reader, .{
            .query = case.query,
            .scope = case.scope,
            .max_depth = case.max_depth,
            .max_results = case.max_results,
        });
        t.* = nowNs() - start;
        count = results.len;
        alloc.free(results);
    }

    std.debug.print("  {s:<28} {d:>9.2} ms   {d:>8} rows\n", .{ case.label, fmtMs(median(times)), count });
}

pub fn main(init: std.process.Init) !void {
    // `format.writeIndex` stamps the index's build time through the global Io
    // handle, so the benchmark wires it up the same way the binaries do.
    zest.runtime.init(init);

    const n: usize = if (std.c.getenv("BENCH_ENTRIES")) |v|
        std.fmt.parseInt(usize, std.mem.span(v), 10) catch 1_000_000
    else
        1_000_000;
    const samples: usize = if (std.c.getenv("BENCH_SAMPLES")) |v|
        std.fmt.parseInt(usize, std.mem.span(v), 10) catch 7
    else
        7;

    std.debug.print("building corpus: {d} entries...\n", .{n});
    const corpus = try buildCorpus(n);
    const data = try format.writeIndex(alloc, corpus.entries);
    defer alloc.free(data);
    std.debug.print("index: {d:.1} MB\n\n", .{@as(f64, @floatFromInt(data.len)) / (1024.0 * 1024.0)});

    var reader = try reader_mod.IndexReader.init(alloc, data);
    defer reader.deinit();

    const scope = corpus.entries[0].dir_path;
    const cases = [_]Case{
        .{ .label = "text 1-char \"e\"", .query = "e" },
        .{ .label = "text 2-char \"re\"", .query = "re" },
        .{ .label = "text \"report\"", .query = "report" },
        .{ .label = "text \"screenshot\"", .query = "screenshot" },
        .{ .label = "text no-match", .query = "qqzzxx" },
        .{ .label = "text non-ascii \"café\"", .query = "café" },
        .{ .label = "text \"report\" capped 100", .query = "report", .max_results = 100 },
        .{ .label = "folder listing (depth 1)", .query = "", .scope = scope, .max_depth = 1 },
        .{ .label = "subtree filter ext:pdf", .query = "ext:pdf", .scope = "/Users/bench" },
    };

    std.debug.print("median of {d} samples\n", .{samples});
    for (cases) |case| {
        // `ext:` is parsed by the C ABI, not the engine — feed the engine the
        // filter directly so this case measures the filter-only scan path.
        if (std.mem.startsWith(u8, case.query, "ext:")) continue;
        try run(&reader, case, samples);
    }

    // Filter-only path (subtree scope + extension filter), built by hand since
    // qualifier parsing lives above the engine in the C ABI layer.
    {
        var ext_filter = filters_mod.FilterCriterion{ .extension = .{} };
        @memcpy(ext_filter.extension.value[0..3], "pdf");
        ext_filter.extension.len = 3;

        const times = try alloc.alloc(u64, samples);
        defer alloc.free(times);
        var count: usize = 0;
        for (times) |*t| {
            const start = nowNs();
            const results = try search_mod.search(alloc, &reader, .{
                .query = "",
                .filters = &.{ext_filter},
                .scope = "/Users/bench",
                .max_results = 100_000,
            });
            t.* = nowNs() - start;
            count = results.len;
            alloc.free(results);
        }
        std.debug.print("  {s:<28} {d:>9.2} ms   {d:>8} rows\n", .{ "subtree filter ext:pdf", fmtMs(median(times)), count });
    }
}
