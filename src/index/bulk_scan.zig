//! Parallel macOS directory scanner using `getattrlistbulk(2)`.
//!
//! Replaces the single-threaded per-file `stat` walk. A fixed pool of worker
//! threads pulls directories off a shared queue; each worker fetches a whole
//! directory's metadata (name + type + allocated size + mtime) in batched
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

/// Number of scan worker threads. 8 remains the measured sweet spot on a
/// 12-core M-series machine; 12 workers overloaded virtual/network filesystem
/// providers and regressed a warm home-directory scan from 22s to 57s.
pub const max_scan_threads: usize = 8;

// --- getattrlistbulk ABI ---
// Per-entry layout (with FSOPT_PACK_INVAL_ATTRS) verified empirically against
// files of known size: +0 u32 entry length; +4 attribute_set_t RETURNED_ATTRS
// (20 bytes); +24 attrreference NAME; +32 u32 OBJTYPE; +36 timespec MODTIME;
// +52 u64 file ALLOCSIZE (present only when its returned-attrs bit is set).

const ATTR_BIT_MAP_COUNT: u16 = 5;
const ATTR_CMN_RETURNED_ATTRS: u32 = 0x80000000;
const ATTR_CMN_NAME: u32 = 0x00000001;
const ATTR_CMN_OBJTYPE: u32 = 0x00000008;
const ATTR_CMN_MODTIME: u32 = 0x00000400;
const ATTR_FILE_ALLOCSIZE: u32 = 0x00000004;
const FSOPT_PACK_INVAL_ATTRS: u64 = 0x00000008;

const VREG: u32 = 1; // regular file (fsobj_type_t)
const VDIR: u32 = 2; // directory
const VLNK: u32 = 5; // symlink

fn allocatedSize(entry: []const u8, returned_fileattrs: u32) u64 {
    if (returned_fileattrs & ATTR_FILE_ALLOCSIZE == 0 or entry.len < 60) return 0;
    return std.mem.readInt(u64, entry[52..][0..8], .little);
}

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

extern "c" fn ftruncate(fd: c_int, length: i64) c_int;
extern "c" fn setiopolicy_np(policy_type: c_int, scope: c_int, policy: c_int) c_int;

// Public Darwin thread policy from <sys/resource.h>. Metadata enumeration of a
// File Provider tree may otherwise materialize an evicted file just to answer
// getattrlistbulk. Opting out makes that entry/directory fail with EDEADLK,
// which the live-filesystem policy below treats as temporarily unavailable.
const IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES: c_int = 3;
const IOPOL_SCOPE_THREAD: c_int = 1;
const IOPOL_MATERIALIZE_DATALESS_FILES_OFF: c_int = 1;

// --- shared work queue ---

const Shared = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    queue: std.ArrayList([]u8) = .empty, // owned absolute dir paths
    pending: usize = 0,
    done: bool = false,
    alloc: std.mem.Allocator,
    total_entries: std.atomic.Value(u64) = .init(0),
    /// Set when an internal scanner failure makes the shard set incomplete.
    /// The builder must reject the result rather than publish partial data.
    scan_failed: std.atomic.Value(bool) = .init(false),
};

const Worker = struct {
    shared: *Shared,
    writer: *std.Io.Writer,
    attr_buf: []u8,
    local_entries: u64 = 0,
};

// A three-run warm-cache A/B on a 3.06M-entry APFS corpus selected 128 KiB:
// median 10.3s versus 11.3s at 2 MiB. Keeping the buffer on the heap avoids
// consuming worker thread stacks and makes its lifetime explicit.
const attr_buffer_size = 128 * 1024;

/// Walk `root` in parallel and write TSV entries to `support_dir`/scan.tmp.{0..N}.
pub const ScanResult = struct {
    paths: []const []u8,
    entry_count: u64,
    complete: bool,
};

/// Returns the temp-file paths, successfully-written record count, and whether
/// every internal scanner operation completed. The caller owns every path and
/// must delete/free them even when `complete` is false.
pub fn parallelScan(
    allocator: std.mem.Allocator,
    root: []const u8,
    support_dir: []const u8,
    n_threads: usize,
) !ScanResult {
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
    var wbuf_count: usize = 0;
    defer {
        for (wbufs[0..wbuf_count]) |b| allocator.free(b);
        allocator.free(wbufs);
    }
    const workers = try allocator.alloc(Worker, n);
    defer allocator.free(workers);
    const attr_bufs = try allocator.alloc([]u8, n);
    var attr_buf_count: usize = 0;
    defer {
        for (attr_bufs[0..attr_buf_count]) |b| allocator.free(b);
        allocator.free(attr_bufs);
    }

    for (0..n) |i| {
        paths[i] = try std.fmt.allocPrint(allocator, "{s}/scan.tmp.{d}", .{ support_dir, i });
        files[i] = try std.Io.Dir.createFileAbsolute(io, paths[i], .{});
        wbufs[i] = try allocator.alloc(u8, 64 * 1024);
        wbuf_count += 1;
        attr_bufs[i] = try allocator.alloc(u8, attr_buffer_size);
        attr_buf_count += 1;
        fwriters[i] = files[i].writer(io, wbufs[i]);
        workers[i] = .{ .shared = &sh, .writer = &fwriters[i].interface, .attr_buf = attr_bufs[i] };
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
        fwriters[i].interface.flush() catch |err| {
            std.debug.print("error: cannot flush scan shard {s}: {}\n", .{ paths[i], err });
            sh.scan_failed.store(true, .monotonic);
        };
        files[i].close(io);
    }

    const complete = !sh.scan_failed.load(.monotonic);
    if (!complete)
        std.debug.print("error: index scan incomplete; refusing to publish its shards\n", .{});

    return .{
        .paths = paths,
        .entry_count = sh.total_entries.load(.monotonic),
        .complete = complete,
    };
}

fn workerMain(w: *Worker) void {
    const sh = w.shared;
    const io = runtime.io;
    if (setiopolicy_np(
        IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
        IOPOL_SCOPE_THREAD,
        IOPOL_MATERIALIZE_DATALESS_FILES_OFF,
    ) != 0) {
        std.debug.print("warning: could not disable dataless-file materialization for scan worker\n", .{});
    }
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
            } else |err| {
                std.debug.print("error: cannot queue directory {s}: {}\n", .{ sd, err });
                sh.scan_failed.store(true, .monotonic);
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
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.AccessDenied, error.PermissionDenied, error.FileNotFound, error.NotDir => {},
            // Network and virtual filesystems (notably OrbStack's NFS mount)
            // can report ESTALE/ENOENT as Unexpected when an entry disappears
            // after it was queued. A live filesystem scan is inherently racy;
            // skip that directory just as we do FileNotFound.
            error.Unexpected => std.debug.print("warning: directory disappeared while scanning: {s}\n", .{path}),
            else => {
                std.debug.print("error: cannot scan directory {s}: {}\n", .{ path, err });
                w.shared.scan_failed.store(true, .monotonic);
            },
        }
        return;
    };
    defer dir.close(io);
    const fd: c_int = @intCast(dir.handle);

    var alist = attrlist_t{
        .bitmapcount = ATTR_BIT_MAP_COUNT,
        .reserved = 0,
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME,
        .volattr = 0,
        .dirattr = 0,
        .fileattr = ATTR_FILE_ALLOCSIZE,
        .forkattr = 0,
    };

    // Hoist path escaping: `path` is invariant for this entire processDir call,
    // so compute esc_path once rather than re-escaping it for every entry.
    var esc_path_buf: [4096 * 2]u8 = undefined;
    const esc_path = format.escapeTsv(&esc_path_buf, path) orelse {
        std.debug.print("error: directory path is too long to encode: {s}\n", .{path});
        w.shared.scan_failed.store(true, .monotonic);
        return;
    };

    // Kernel time in getattrlistbulk dominates the walk, but oversized batches
    // add cache pressure. Keep this synchronized with the measured constant.
    const buf = w.attr_buf;
    while (true) {
        const rc = getattrlistbulk(fd, &alist, buf.ptr, buf.len, FSOPT_PACK_INVAL_ATTRS);
        if (rc < 0) {
            const errno = std.posix.errno(rc);
            // ERANGE means not even one record fit. Retrying the same buffer
            // can loop forever; 128 KiB is already far larger than a legal
            // Darwin directory record, so treat it as malformed/unsupported.
            if (errno == .RANGE) {
                std.debug.print("error: bulk record exceeds {d}-byte buffer for {s}\n", .{ buf.len, path });
                w.shared.scan_failed.store(true, .monotonic);
                return;
            }
            // Live virtual/network filesystems can disappear or time out while
            // a scan is in progress. Keep the rest of the index usable.
            if (errno == .NOENT or errno == .STALE or errno == .TIMEDOUT or errno == .DEADLK) {
                std.debug.print("warning: directory became unavailable while scanning {s}: {}\n", .{ path, errno });
                return;
            }
            std.debug.print("error: getattrlistbulk failed for {s}: {}\n", .{ path, errno });
            w.shared.scan_failed.store(true, .monotonic);
            return;
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
            if (off + 4 > buf.len) {
                std.debug.print("error: malformed bulk record header for {s}\n", .{path});
                w.shared.scan_failed.store(true, .monotonic);
                return;
            }
            const entry = buf[off..];
            const entry_len = std.mem.readInt(u32, entry[0..4], .little);
            // 44 covers the fixed reads through MODTIME (entry[36..44]).
            if (entry_len < 44 or off + entry_len > buf.len) {
                std.debug.print("error: malformed bulk record length for {s}: {d}\n", .{ path, entry_len });
                w.shared.scan_failed.store(true, .monotonic);
                return;
            }

            // Fixed common-group layout (RETURNED_ATTRS always returns
            // NAME/OBJTYPE/MODTIME). ALLOCSIZE (file group) is present only when
            // its returned-attrs bit is set — absent for directories.
            const ret_fileattr = std.mem.readInt(u32, entry[16..][0..4], .little);
            const name_dataoff = std.mem.readInt(i32, entry[24..][0..4], .little);
            const name_len = std.mem.readInt(u32, entry[28..][0..4], .little);
            const objtype = std.mem.readInt(u32, entry[32..][0..4], .little);
            const mtime = std.mem.readInt(i64, entry[36..][0..8], .little); // timespec.tv_sec
            const size = allocatedSize(entry[0..entry_len], ret_fileattr);

            off += entry_len;

            // name_dataoff is relative to the attr-ref field at offset 24;
            // validate the resulting slice lies inside this entry before reading.
            const name_field_base: i64 = 24 + @as(i64, name_dataoff);
            if (name_field_base < 0) {
                std.debug.print("error: malformed bulk name offset for {s}\n", .{path});
                w.shared.scan_failed.store(true, .monotonic);
                return;
            }
            const name_start: usize = @intCast(name_field_base);
            if (name_start + name_len > entry_len) {
                std.debug.print("error: malformed bulk name length for {s}\n", .{path});
                w.shared.scan_failed.store(true, .monotonic);
                return;
            }
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
                    const cp = std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, name }) catch |err| {
                        std.debug.print("error: cannot allocate directory path under {s}: {}\n", .{ path, err });
                        w.shared.scan_failed.store(true, .monotonic);
                        continue;
                    };
                    if (config.shouldExcludePath(cp)) {
                        alloc.free(cp);
                        continue;
                    }
                    subdirs.append(alloc, cp) catch |err| {
                        std.debug.print("error: cannot queue discovered directory {s}: {}\n", .{ cp, err });
                        w.shared.scan_failed.store(true, .monotonic);
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
                std.debug.print("error: filename is too long to encode under {s} ({d} bytes)\n", .{ path, name.len });
                w.shared.scan_failed.store(true, .monotonic);
                continue;
            };

            w.writer.print("{s}\t{s}\t{d}\t{d}\t{d}\t{d}\n", .{
                esc_name, esc_path, size, mtime, @intFromEnum(kind), @intFromEnum(cat),
            }) catch |err| {
                // Don't count an entry we failed to write — the old code bumped
                // local_entries unconditionally, overstating the index size.
                std.debug.print("error: cannot write scan shard while scanning {s}: {}\n", .{ path, err });
                w.shared.scan_failed.store(true, .monotonic);
                return;
            };
            w.local_entries += 1;
        }
    }
}

test "scanner reads allocated size rather than logical data length" {
    var entry = [_]u8{0} ** 60;
    std.mem.writeInt(u64, entry[52..60], 12_396_843_008, .little);

    try std.testing.expectEqual(
        @as(u64, 12_396_843_008),
        allocatedSize(&entry, ATTR_FILE_ALLOCSIZE),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        allocatedSize(&entry, ATTR_FILE_DATALENGTH_FOR_TEST),
    );
    try std.testing.expectEqual(@as(u64, 0), allocatedSize(entry[0..59], ATTR_FILE_ALLOCSIZE));
}

test "parallel scanner reports sparse file allocation" {
    const io = runtime.io;
    const allocator = std.testing.allocator;
    const logical_size: i64 = 1024 * 1024 * 1024;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var data_dir = try tmp.dir.createDirPathOpen(io, "data", .{});
    defer data_dir.close(io);
    var support_dir = try tmp.dir.createDirPathOpen(io, "support", .{});
    defer support_dir.close(io);

    var sparse = try data_dir.createFile(io, "sparse.img", .{});
    const truncate_result = ftruncate(@intCast(sparse.handle), logical_size);
    sparse.close(io);
    try std.testing.expectEqual(@as(c_int, 0), truncate_result);

    const root = try tmp.dir.realPathFileAlloc(io, "data", allocator);
    defer allocator.free(root);
    const support = try tmp.dir.realPathFileAlloc(io, "support", allocator);
    defer allocator.free(support);

    const scan = try parallelScan(allocator, root, support, 1);
    defer {
        for (scan.paths) |path| allocator.free(path);
        allocator.free(scan.paths);
    }
    try std.testing.expect(scan.complete);
    try std.testing.expectEqual(@as(u64, 1), scan.entry_count);

    const shard = try runtime.readFileAlloc(allocator, scan.paths[0], .limited(4096));
    defer allocator.free(shard);
    var fields = std.mem.splitScalar(u8, std.mem.trimEnd(u8, shard, "\n"), '\t');
    _ = fields.next() orelse return error.MalformedScanRecord;
    _ = fields.next() orelse return error.MalformedScanRecord;
    const allocated = try std.fmt.parseInt(u64, fields.next() orelse return error.MalformedScanRecord, 10);
    try std.testing.expect(allocated < @as(u64, @intCast(logical_size)));
}

// The logical-length bit is deliberately test-only: production requests only
// ALLOCSIZE, and the parser must not mistake a DATALENGTH-only response for it.
const ATTR_FILE_DATALENGTH_FOR_TEST: u32 = 0x00000200;
