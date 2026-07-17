//! Parallel macOS directory scanner using `getattrlistbulk(2)`.
//!
//! Replaces the single-threaded per-file `stat` walk. A fixed pool of worker
//! threads pulls directories off a shared queue; each worker fetches a whole
//! directory's metadata (name + type + size + mtime) in batched
//! `getattrlistbulk` syscalls and streams TSV entries into its OWN temp file.
//! `buildIndex` then reads all the temp files back (order is irrelevant to the
//! columnar builder).
//!
//! Why this shape: measured on a 5.7M-file home dir, parallelizing the per-file
//! `stat` walk gave only ~1.25x (the std.Io per-call path serializes), while
//! `getattrlistbulk` (a raw libc call that bypasses std.Io) parallelized to
//! ~6.6x (155s -> ~23s).
//!
//! macOS only (getattrlistbulk is a Darwin syscall); the whole project is.

const std = @import("std");
const types = @import("../core/types.zig");
const file_types = @import("../core/file_types.zig");
const config = @import("../config/config.zig");
const runtime = @import("../core/runtime.zig");
const format = @import("format.zig");

/// Number of scan worker threads. 8 was the measured sweet spot (x4=5.2x,
/// x8=6.6x) on a 12-core machine; more gave diminishing returns.
pub const max_scan_threads: usize = 8;

// --- getattrlistbulk ABI ---
// Per-entry layout (with FSOPT_PACK_INVAL_ATTRS) verified empirically against
// files of known size: +0 u32 entry length; +4 attribute_set_t RETURNED_ATTRS
// (20 bytes); +24 attrreference NAME; +32 u32 OBJTYPE; +36 timespec MODTIME;
// +52 u64 file DATALENGTH (present only when its returned-attrs bit is set).

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;
const ATTR_CMN_NAME: u32 = 0x00000001;
const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
const ATTR_CMN_MODTIME: u32 = 0x00000400;
const ATTR_FILE_DATALENGTH: u32 = 0x00000200;
const FSOPT_PACK_INVAL_ATTRS: u64 = 0x00000008;

const VREG: u32 = 1; // regular file (fsobj_type_t)
const VDIR: u32 = 2; // directory
const VLNK: u32 = 5; // symlink

const attrlist_t = extern struct {
    bitmapcount: u16,
    reserved: u16,
    commonattr: u32,
    volattr: u32,
    dirattr: u32,
    fileattr: u32,
    forkattr: u32,
};

extern "c" fn getattrlistbulk(
    dirfd: c_int,
    alist: *attrlist_t,
    attrBuf: *anyopaque,
    attrBufSize: usize,
    options: u64,
) c_int;

// --- shared work queue ---

const Shared = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayList([]u8) = .empty, // owned absolute dir paths
    pending: usize = 0,
    done: bool = false,
    alloc: std.mem.Allocator,
    total_entries: std.atomic.Value(u64) = .init(0),
    /// Set when a worker drops an entry or subdirectory (write/flush/OOM), so
    /// the caller can report that the published index may be incomplete instead
    /// of silently shipping a short index with an overstated count.
    write_failed: std.atomic.Value(bool) = .init(false),
};

const Worker = struct {
    shared: *Shared,
    writer: *std.Io.Writer,
    local_entries: u64 = 0,
};

/// Walk `root` in parallel and write TSV entries to `support_dir`/scan.tmp.{0..N}.
/// Returns the list of temp-file paths (caller owns them: read, then delete).
/// `entries_out` receives the total entry count (for progress/logging).
pub fn parallelScan(
    allocator: std.mem.Allocator,
    root: []const u8,
    support_dir: []const u8,
    n_threads: usize,
    entries_out: *u64,
) ![]const []u8 {
    const io = runtime.io;
    const n = @max(1, n_threads);

    var sh = Shared{ .alloc = allocator };
    defer sh.queue.deinit(allocator);
    try sh.queue.append(allocator, try allocator.dupe(u8, root));
    sh.pending = 1;

    // Per-worker temp files + buffered writers (each writer needs a stable
    // buffer and a stable File.Writer slot, so heap-allocate the arrays).
    const paths = try allocator.alloc([]u8, n);
    errdefer allocator.free(paths);
    const files = try allocator.alloc(std.Io.File, n);
    defer allocator.free(files);
    const fwriters = try allocator.alloc(std.Io.File.Writer, n);
    defer allocator.free(fwriters);
    const wbufs = try allocator.alloc([]u8, n);
    defer {
        for (wbufs) |b| allocator.free(b);
        allocator.free(wbufs);
    }
    const workers = try allocator.alloc(Worker, n);
    defer allocator.free(workers);

    for (0..n) |i| {
        paths[i] = try std.fmt.allocPrint(allocator, "{s}/scan.tmp.{d}", .{ support_dir, i });
        files[i] = try std.Io.Dir.createFileAbsolute(io, paths[i], .{});
        wbufs[i] = try allocator.alloc(u8, 64 * 1024);
        fwriters[i] = files[i].writer(io, wbufs[i]);
        workers[i] = .{ .shared = &sh, .writer = &fwriters[i].interface };
    }

    const threads = try allocator.alloc(std.Thread, n);
    defer allocator.free(threads);
    var spawned: usize = 0;
    for (threads, 0..) |*t, i| {
        t.* = std.Thread.spawn(.{}, workerMain, .{&workers[i]}) catch |err| {
            // Threads 0..spawned hold pointers into workers/wbufs/sh, which the
            // defers above free on error — stop and join them first or they
            // race a freed queue.
            sh.mutex.lockUncancelable(io);
            sh.done = true;
            sh.cond.broadcast(io);
            sh.mutex.unlock(io);
            for (threads[0..spawned]) |st| st.join();
            return err;
        };
        spawned += 1;
    }
    for (threads) |t| t.join();

    // Flush and close each worker's temp file.
    for (0..n) |i| {
        fwriters[i].interface.flush() catch sh.write_failed.store(true, .monotonic);
        files[i].close(io);
    }

    if (sh.write_failed.load(.monotonic))
        std.debug.print("warning: index scan dropped entries (write/queue failure); the index may be incomplete\n", .{});

    entries_out.* = sh.total_entries.load(.monotonic);
    return paths;
}

fn workerMain(w: *Worker) void {
    const sh = w.shared;
    const io = runtime.io;
    while (true) {
        sh.mutex.lockUncancelable(io);
        while (sh.queue.items.len == 0 and !sh.done) sh.cond.waitUncancelable(io, &sh.mutex);
        if (sh.queue.items.len == 0 and sh.done) {
            sh.mutex.unlock(io);
            break;
        }
        const dir_path = sh.queue.pop() orelse {
            sh.mutex.unlock(io);
            continue;
        };
        sh.mutex.unlock(io);

        var subdirs: std.ArrayList([]u8) = .empty;
        processDir(dir_path, w, &subdirs, sh.alloc);
        sh.alloc.free(dir_path);

        sh.mutex.lockUncancelable(io);
        var appended: usize = 0;
        for (subdirs.items) |sd| {
            if (sh.queue.append(sh.alloc, sd)) {
                appended += 1;
            } else |_| {
                sh.write_failed.store(true, .monotonic);
                sh.alloc.free(sd);
            }
        }
        sh.pending += appended;
        sh.pending -= 1;
        if (sh.pending == 0) {
            sh.done = true;
            sh.cond.broadcast(io);
        } else if (appended > 0) {
            sh.cond.broadcast(io);
        }
        sh.mutex.unlock(io);
        subdirs.deinit(sh.alloc);
    }
    _ = sh.total_entries.fetchAdd(w.local_entries, .monotonic);
}

/// Scan one directory via getattrlistbulk, writing TSV lines for its entries
/// and collecting non-excluded subdirectory paths into `subdirs`.
fn processDir(path: []const u8, w: *Worker, subdirs: *std.ArrayList([]u8), alloc: std.mem.Allocator) void {
    const io = runtime.io;
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const fd: c_int = @intCast(dir.handle);

    var alist = attrlist_t{
        .bitmapcount = ATTR_BIT_MAP_COUNT,
        .reserved = 0,
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME,
        .volattr = 0,
        .dirattr = 0,
        .fileattr = ATTR_FILE_DATALENGTH,
        .forkattr = 0,
    };

    // Hoist path escaping: `path` is invariant for this entire processDir call,
    // so compute esc_path once rather than re-escaping it for every entry.
    var esc_path_buf: [4096 * 2]u8 = undefined;
    const esc_path = format.escapeTsv(&esc_path_buf, path) orelse {
        w.shared.write_failed.store(true, .monotonic);
        return;
    };

    var buf: [128 * 1024]u8 align(8) = undefined;
    while (true) {
        const rc = getattrlistbulk(fd, &alist, &buf, buf.len, FSOPT_PACK_INVAL_ATTRS);
        if (rc < 0) {
            // APFS returns ERANGE when a call exactly fills the buffer; retry.
            if (std.posix.errno(rc) == .RANGE) continue;
            break; // other error: stop scanning this directory
        }
        if (rc == 0) break; // end of directory
        const count: usize = @intCast(rc);

        var off: usize = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            // This parses the getattrlistbulk ABI by hand with fixed offsets, so
            // bound every read against the returned buffer and the entry's own
            // declared length — a kernel/FS layout change must stop the walk,
            // not read stack garbage into a filename.
            if (off + 4 > buf.len) break;
            const entry = buf[off..];
            const entry_len = std.mem.readInt(u32, entry[0..4], .little);
            // 44 covers the fixed reads through MODTIME (entry[36..44]).
            if (entry_len < 44 or off + entry_len > buf.len) break;

            // Fixed common-group layout (RETURNED_ATTRS always returns
            // NAME/OBJTYPE/MODTIME). DATALENGTH (file group) is present only when
            // its returned-attrs bit is set — absent for directories.
            const ret_fileattr = std.mem.readInt(u32, entry[16..][0..4], .little);
            const name_dataoff = std.mem.readInt(i32, entry[24..][0..4], .little);
            const name_len = std.mem.readInt(u32, entry[28..][0..4], .little);
            const objtype = std.mem.readInt(u32, entry[32..][0..4], .little);
            const mtime = std.mem.readInt(i64, entry[36..][0..8], .little); // timespec.tv_sec
            const size: u64 = if (ret_fileattr & ATTR_FILE_DATALENGTH != 0 and entry_len >= 60)
                std.mem.readInt(u64, entry[52..][0..8], .little)
            else
                0;

            off += entry_len;

            // name_dataoff is relative to the attr-ref field at offset 24;
            // validate the resulting slice lies inside this entry before reading.
            const name_field_base: i64 = 24 + @as(i64, name_dataoff);
            if (name_field_base < 0) continue;
            const name_start: usize = @intCast(name_field_base);
            if (name_start + name_len > entry_len) continue;
            var name = entry[name_start..][0..name_len];
            if (name.len > 0 and name[name.len - 1] == 0) name = name[0 .. name.len - 1];

            if (config.shouldExclude(name)) continue;
            if (name.len > 0 and name[0] == '.') continue;

            const kind: types.FileKind = switch (objtype) {
                VDIR => .directory,
                VLNK => .symlink,
                else => .file,
            };

            if (kind == .directory) {
                if (path.len + 1 + name.len <= 4096) {
                    const cp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, name }) catch {
                        w.shared.write_failed.store(true, .monotonic);
                        continue;
                    };
                    if (config.shouldExcludePath(cp)) {
                        alloc.free(cp);
                        continue;
                    }
                    subdirs.append(alloc, cp) catch {
                        w.shared.write_failed.store(true, .monotonic);
                        alloc.free(cp);
                    };
                } else continue; // path too long for the buffer; record entry, don't recurse
            }

            const cat: types.FileCategory = if (kind == .directory) .uncategorized else file_types.categorize(name);

            // Escape tab/newline/backslash so a filename like "we\tird" (legal
            // on APFS) doesn't shear the TSV line. esc_path was hoisted above
            // the loop (path is invariant); only the name buffer is per-entry.
            // Name buffer is sized at 2× NAME_MAX (255 bytes).
            var esc_name_buf: [255 * 2]u8 = undefined;
            const esc_name = format.escapeTsv(&esc_name_buf, name) orelse {
                w.shared.write_failed.store(true, .monotonic);
                continue;
            };

            w.writer.print("{s}\t{s}\t{d}\t{d}\t{d}\t{d}\n", .{
                esc_name, esc_path, size, mtime, @intFromEnum(kind), @intFromEnum(cat),
            }) catch {
                // Don't count an entry we failed to write — the old code bumped
                // local_entries unconditionally, overstating the index size.
                w.shared.write_failed.store(true, .monotonic);
                continue;
            };
            w.local_entries += 1;
        }
    }
}
