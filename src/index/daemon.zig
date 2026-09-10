const std = @import("std");
const builder = @import("builder.zig");
const config = @import("../config/config.zig");
const fsevents = @import("fsevents.zig");
const startup = @import("startup.zig");
const schedule = @import("schedule.zig");
const service = @import("service.zig");
const runtime = @import("../core/runtime.zig");
const humanize = @import("../core/humanize.zig");
const progress = @import("progress.zig");
const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
});

var dirty_count = std.atomic.Value(usize).init(0);
var watch_root: []const u8 = "";
var exclude_prefix: []const u8 = "";

fn onFSEvent(paths: []const []const u8, must_rescan: bool) void {
    var relevant: usize = if (must_rescan) schedule.event_threshold else 0;
    for (paths) |path| {
        if (!config.shouldExcludeDescendant(path, watch_root, exclude_prefix)) relevant +|= 1;
    }
    if (relevant == 0) return;
    const total = dirty_count.fetchAdd(relevant, .monotonic) +| relevant;
    if (total >= schedule.event_threshold) c.CFRunLoopStop(c.CFRunLoopGetCurrent());
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (try service.handle(allocator, args)) return;
    var full_scan = false;
    var scan_root: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--full-scan")) {
            full_scan = true;
        } else if (std.mem.startsWith(u8, arg, "-") or scan_root != null) {
            return error.UnexpectedArgument;
        } else scan_root = arg;
    }
    const home = try runtime.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    try config.ensureAppSupportDir(allocator);
    // Match FSEvents' canonical spelling for symlinked homes and /private/tmp.
    const root = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io, scan_root orelse home, allocator);
    defer allocator.free(root);
    if (full_scan) try runFullScan(allocator, root, false) else try runDaemon(allocator, root);
}

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
            std.debug.print("error: initial scan failed: {}; retrying in 5s\n", .{err});
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
    defer {
        watch_root = "";
        exclude_prefix = "";
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
    if (!ops.initial_ok) state.failed(runtime.nowNanos());
    while (true) {
        _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, 2.0, 0);
        state.add(dirty_count.swap(0, .monotonic));
        const request = readRequest(ops.request_path);
        const requested = if (request) |token| if (ops.request_seen) |seen| !std.mem.eql(u8, &token, &seen) else true else false;
        if (!state.due(runtime.nowNanos(), requested)) continue;
        std.debug.print("Rebuilding index ({d} events, requested={}, retry={d})...\n", .{ state.pending, requested, state.failures });
        runFullScan(ops.allocator, ops.root, true) catch |err| {
            state.failed(runtime.nowNanos());
            std.debug.print("error: rebuild failed: {}; retry in {d}s\n", .{ err, @divTrunc(state.retry_at - runtime.nowNanos(), std.time.ns_per_s) + 1 });
            continue;
        };
        state.succeeded(runtime.nowNanos());
        ops.request_seen = request;
    }
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
