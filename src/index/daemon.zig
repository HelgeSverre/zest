const std = @import("std");
const cli = @import("../core/cli.zig");
const builder = @import("builder.zig");
const config = @import("../config/config.zig");
const fsevents = @import("fsevents.zig");
const startup = @import("startup.zig");
const schedule = @import("schedule.zig");
const service = @import("service.zig");
const runtime = @import("../core/runtime.zig");
const humanize = @import("../core/humanize.zig");
const progress = @import("progress.zig");
const incremental = @import("incremental.zig");
const format = @import("format.zig");
const c = fsevents.c;

var dirty_count = std.atomic.Value(usize).init(0);
var watch_root: []const u8 = "";
var exclude_prefix: []const u8 = "";
// The FSEvents stream is scheduled on the main thread's run loop, so the
// callback and the watch loop never run concurrently: no lock needed.
var dirty_alloc: std.mem.Allocator = undefined;
var dirty_dirs: std.StringHashMapUnmanaged(void) = .{};
var needs_full = false;

/// Directory-level events: each path is a directory whose contents changed.
fn onFSEvent(paths: []const []const u8, must_rescan: bool) void {
    if (must_rescan) needs_full = true;
    var relevant: usize = if (must_rescan) schedule.event_threshold else 0;
    for (paths) |raw| {
        const path = if (raw.len > 1) std.mem.trimEnd(u8, raw, "/") else raw;
        if (config.shouldExcludeDescendant(path, watch_root, exclude_prefix)) continue;
        relevant +|= 1;
        if (dirty_dirs.contains(path)) continue;
        const owned = dirty_alloc.dupe(u8, path) catch {
            needs_full = true;
            continue;
        };
        dirty_dirs.put(dirty_alloc, owned, {}) catch {
            dirty_alloc.free(owned);
            needs_full = true;
        };
    }
    if (relevant == 0) return;
    const total = dirty_count.fetchAdd(relevant, .monotonic) +| relevant;
    if (total >= schedule.event_threshold) c.zest_run_loop_stop();
}

/// Hand the accumulated dirty set to the caller (owned keys) and start a fresh one.
fn takeDirty(allocator: std.mem.Allocator) ![]const []const u8 {
    var taken = dirty_dirs;
    dirty_dirs = .{};
    defer taken.deinit(dirty_alloc);
    const dirs = try allocator.alloc([]const u8, taken.count());
    var it = taken.keyIterator();
    var i: usize = 0;
    while (it.next()) |k| : (i += 1) dirs[i] = k.*;
    return dirs;
}

fn freeDirty(allocator: std.mem.Allocator, dirs: []const []const u8) void {
    for (dirs) |d| dirty_alloc.free(d);
    allocator.free(dirs);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (cli.handleCommon(args, "zest-indexer", usage)) return;
    if (try service.handle(allocator, args)) return;
    var full_scan = false;
    var scan_root: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--full-scan")) {
            full_scan = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            cli.fail("zest-indexer", "unknown option '{s}'", .{arg});
        } else if (scan_root != null) {
            cli.fail("zest-indexer", "unexpected argument '{s}'", .{arg});
        } else scan_root = arg;
    }
    const home = try runtime.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    try config.ensureAppSupportDir(allocator);
    // Match FSEvents' canonical spelling for symlinked homes and /private/tmp.
    const root = std.Io.Dir.cwd().realPathFileAlloc(runtime.io, scan_root orelse home, allocator) catch |err|
        cli.fail("zest-indexer", "cannot resolve root '{s}' ({t}); expected a command or a directory", .{ scan_root orelse home, err });
    defer allocator.free(root);
    if (full_scan) try runFullScan(allocator, root, false) else try runDaemon(allocator, root);
}

const usage =
    \\Usage: zest-indexer [COMMAND] [OPTIONS] [ROOT]
    \\
    \\Build and maintain the Zest search index. With no command it runs the
    \\indexer in the foreground (initial scan, then FSEvents watching); this is
    \\what the launchd agent invokes. ROOT defaults to $HOME.
    \\
    \\Commands:
    \\  install            Install and start the launchd background agent
    \\  uninstall          Stop and remove the launchd agent
    \\  status             Print agent state (running, waiting, stopped, ...)
    \\  start | stop       Start or stop the agent
    \\  restart            Restart the agent
    \\  reindex            Ask the running agent for a full rescan
    \\
    \\Options:
    \\  --full-scan [ROOT] Scan once, write the index, and exit
    \\  -h, --help         Show this help
    \\  -V, --version      Print version
    \\
    \\Diagnostics:
    \\  prepare-install [--binary-path PATH]
    \\                     Stage the agent binary without starting it
    \\  probe-access       Report whether Full Disk Access is granted
    \\
    \\Examples:
    \\  zest-indexer install
    \\  zest-indexer --full-scan ~/code
    \\  zest-indexer status
    \\
;

const DaemonStartup = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    request_path: []const u8,
    watcher: *fsevents.FSEventsWatcher,
    watcher_started: bool = false,
    initial_ok: bool = false,
    request_seen: ?[16]u8 = null,

    pub fn startWatcher(self: *DaemonStartup) !void {
        try self.watcher.start();
        self.watcher_started = true;
    }
    pub fn initialScan(self: *DaemonStartup) !void {
        self.request_seen = readRequest(self.request_path);
        runFullScan(self.allocator, self.root, true) catch |err| {
            runtime.warn("error: initial scan failed: {}; retrying in 5s\n", .{err});
            return;
        };
        self.initial_ok = true;
    }
    pub fn watchLoop(self: *DaemonStartup) !void {
        try runWatchLoop(self);
    }
};

fn runDaemon(allocator: std.mem.Allocator, root: []const u8) !void {
    const support = try config.appSupportDir(allocator);
    defer allocator.free(support);
    const canonical_support = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io, support, allocator);
    defer allocator.free(canonical_support);
    watch_root = root;
    exclude_prefix = canonical_support;
    dirty_alloc = allocator;
    defer {
        watch_root = "";
        exclude_prefix = "";
        var it = dirty_dirs.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        dirty_dirs.deinit(allocator);
    }
    const request_path = try std.fs.path.join(allocator, &.{ support, service.request_filename });
    defer allocator.free(request_path);
    std.debug.print("Starting FSEvents watcher on {s}...\n", .{root});
    var watcher: fsevents.FSEventsWatcher = undefined;
    try watcher.init(allocator, root, &.{canonical_support}, onFSEvent);
    defer watcher.deinit();
    var ops = DaemonStartup{ .allocator = allocator, .root = root, .request_path = request_path, .watcher = &watcher };
    defer if (ops.watcher_started) watcher.stop();
    try startup.run(&ops);
}

/// Never delete the request file: a request arriving during a scan must survive
/// that scan's completion. Only acknowledge the token captured before scanning.
fn readRequest(path: []const u8) ?[16]u8 {
    const file = std.Io.Dir.openFileAbsolute(runtime.io, path, .{}) catch return null;
    defer file.close(runtime.io);
    var token: [16]u8 = undefined;
    var buffer: [32]u8 = undefined;
    var reader = file.reader(runtime.io, &buffer);
    reader.interface.readSliceAll(&token) catch return null;
    return token;
}

fn runWatchLoop(ops: *DaemonStartup) !void {
    std.debug.print("Watcher active. Rebuild after 30s or 1000 events; failures retry with backoff.\n", .{});
    var state = schedule.Schedule{ .last_success = runtime.nowNanos() };
    var last_full = runtime.nowNanos();
    if (!ops.initial_ok) state.failed(runtime.nowNanos());
    while (true) {
        c.zest_run_loop_run(2.0);
        state.add(dirty_count.swap(0, .monotonic));
        const request = readRequest(ops.request_path);
        const requested = if (request) |token| if (ops.request_seen) |seen| !std.mem.eql(u8, &token, &seen) else true else false;
        const now = runtime.nowNanos();
        if (!state.due(now, requested)) continue;
        // Explicit requests, dropped events, failures, and the daily safety
        // scan take the full walk; ordinary change batches are spliced in.
        const dirs = try takeDirty(ops.allocator);
        defer freeDirty(ops.allocator, dirs);
        var full = requested or needs_full or dirs.len == 0 or now - last_full >= 24 * 3600 * std.time.ns_per_s;
        std.debug.print("Rebuilding index ({d} events in {d} dirs, requested={}, retry={d}, {s})...\n", .{
            state.pending, dirs.len, requested, state.failures, if (full) "full" else "incremental",
        });
        if (!full) runIncremental(ops.allocator, ops.root, dirs) catch |err| {
            std.debug.print("incremental rebuild failed: {}; running a full scan\n", .{err});
            full = true;
        };
        if (full) runFullScan(ops.allocator, ops.root, true) catch |err| {
            state.failed(runtime.nowNanos());
            needs_full = true;
            std.debug.print("error: rebuild failed: {}; retry in {d}s\n", .{ err, @divTrunc(state.retry_at - runtime.nowNanos(), std.time.ns_per_s) + 1 });
            continue;
        };
        if (full) last_full = now;
        needs_full = false;
        state.succeeded(runtime.nowNanos());
        ops.request_seen = request;
    }
}

/// Relist only the changed directories and splice them into the previous index.
fn runIncremental(allocator: std.mem.Allocator, root: []const u8, dirty: []const []const u8) !void {
    const support = try config.appSupportDir(allocator);
    defer allocator.free(support);
    const support_dir = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io, support, allocator);
    defer allocator.free(support_dir);
    const path = try config.indexPath(allocator);
    defer allocator.free(path);
    const old = try runtime.readFileAlloc(allocator, path, .unlimited);
    defer allocator.free(old);
    var reporter: ?progress.Reporter = progress.Reporter.init(allocator, support, true) catch null;
    const report: ?*progress.Reporter = if (reporter) |*value| value else null;
    if (report) |value| value.start();
    defer if (report) |value| value.deinit();
    errdefer |err| if (report) |value| value.setPhase(.failed, @errorName(err));

    var strings = std.heap.ArenaAllocator.init(allocator);
    defer strings.deinit();
    var entries: std.ArrayList(format.IndexEntry) = .empty;
    defer entries.deinit(allocator);
    const t_merge = runtime.nowNanos();
    const stats = try incremental.merge(allocator, strings.allocator(), old, dirty, root, support_dir, &entries);
    if (report) |value| {
        value.discovered(stats.after, root);
        value.setPhase(.building, "");
    }
    const t_build = runtime.nowNanos();
    const index_data = try format.writeIndex(allocator, entries.items);
    defer allocator.free(index_data);
    var merge_buf: [16]u8 = undefined;
    var build_buf: [16]u8 = undefined;
    std.debug.print("  incremental: relisted {d} dirs, rescanned {d} subtrees, dropped {d}, entries {d} -> {d}\n  timing: merge={s} build={s}\n", .{
        stats.relisted,                                                                  stats.rescanned,                                                                            stats.dropped, stats.before, stats.after,
        humanize.duration(&merge_buf, @divTrunc(t_build - t_merge, std.time.ns_per_ms)), humanize.duration(&build_buf, @divTrunc(runtime.nowNanos() - t_build, std.time.ns_per_ms)),
    });
    try publish(report, path, index_data);
}

fn runFullScan(allocator: std.mem.Allocator, root: []const u8, daemon: bool) !void {
    const support = try config.appSupportDir(allocator);
    defer allocator.free(support);
    var reporter: ?progress.Reporter = progress.Reporter.init(allocator, support, daemon) catch null;
    const report: ?*progress.Reporter = if (reporter) |*value| value else null;
    if (report) |value| value.start();
    defer if (report) |value| value.deinit();
    errdefer |err| if (report) |value| value.setPhase(.failed, @errorName(err));
    std.debug.print("Building index for {s}...\n", .{root});
    const index_data = try builder.buildIndexWithProgress(allocator, root, report);
    defer allocator.free(index_data);
    const path = try config.indexPath(allocator);
    defer allocator.free(path);
    try publish(report, path, index_data);
}

/// Atomically replace the index file (via the reporter when one is active).
fn publish(report: ?*progress.Reporter, path: []const u8, index_data: []const u8) !void {
    const t_write = runtime.nowNanos();
    if (report) |value| try value.writeIndex(path, index_data) else try runtime.writeFileAtomic(path, index_data);
    var write_buf: [16]u8 = undefined;
    var size_buf: [16]u8 = undefined;
    std.debug.print("  timing: write={s}\nIndex built: {s} at {s}\n", .{
        humanize.duration(&write_buf, @divTrunc(runtime.nowNanos() - t_write, std.time.ns_per_ms)),
        humanize.bytes(&size_buf, index_data.len),
        path,
    });
}
