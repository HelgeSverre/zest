//! Best-effort UI telemetry. Never lets a failed status write fail an index build.
//! Separate process files keep concurrent development scans from sharing state.
const std = @import("std");
const runtime = @import("../core/runtime.zig");

pub const Phase = enum { scanning, building, writing, published, failed };
pub const Reporter = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    run_id: [32]u8,
    started: i128,
    started_at: i64,
    mutex: std.Io.Mutex = .init,
    phase: Phase = .scanning,
    current: [4096]u8 = undefined,
    current_len: usize = 0,
    message: []const u8 = "",
    count: std.atomic.Value(u64) = .init(0),
    path_second: std.atomic.Value(i64) = .init(0),
    written: std.atomic.Value(u64) = .init(0),
    total: u64 = 0,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, support: []const u8, daemon: bool) !Reporter {
        const path = if (daemon)
            try std.fs.path.join(allocator, &.{ support, "progress-daemon.json" })
        else
            try std.fmt.allocPrint(allocator, "{s}/progress-manual-{d}.json", .{ support, std.c.getpid() });
        var random: u128 = undefined;
        runtime.io.random(std.mem.asBytes(&random));
        var run_id: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&run_id, "{x:0>32}", .{random}) catch unreachable;
        return .{ .allocator = allocator, .path = path, .run_id = run_id, .started = runtime.nowNanos(), .started_at = runtime.unixTimestamp() };
    }

    pub fn start(self: *Reporter) void {
        self.emit();
        self.thread = std.Thread.spawn(.{}, heartbeat, .{self}) catch null;
    }

    pub fn deinit(self: *Reporter) void {
        self.stopping.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.emit();
        // Successful one-shot scans need no persistent status once the index
        // exists. Keep failures for diagnostics; daemon has one bounded file.
        if (self.phase == .published and std.mem.indexOf(u8, self.path, "/progress-manual-") != null)
            std.Io.Dir.deleteFileAbsolute(runtime.io, self.path) catch {};
        self.allocator.free(self.path);
    }

    fn heartbeat(self: *Reporter) void {
        var ticks: u8 = 0;
        while (!self.stopping.load(.acquire)) {
            std.Io.sleep(runtime.io, .fromMilliseconds(250), .awake) catch return;
            ticks +%= 1;
            if (ticks % 4 == 0) self.emit();
        }
    }

    /// Called once per kernel batch, not once per file. Only one worker samples
    /// a path per second; no filesystem writes happen on scan worker threads.
    pub fn discovered(self: *Reporter, count: u64, path: []const u8) void {
        _ = self.count.fetchAdd(count, .monotonic);
        const second = runtime.unixTimestamp();
        if (self.path_second.swap(second, .monotonic) == second) return;
        self.mutex.lockUncancelable(runtime.io);
        defer self.mutex.unlock(runtime.io);
        // Some legal Unix filenames aren't UTF-8. Never let them invalidate JSON.
        self.current_len = if (path.len <= self.current.len and std.unicode.utf8ValidateSlice(path)) path.len else 0;
        @memcpy(self.current[0..self.current_len], path[0..self.current_len]);
    }

    pub fn setPhase(self: *Reporter, phase: Phase, message: []const u8) void {
        self.mutex.lockUncancelable(runtime.io);
        self.phase = phase;
        self.message = message;
        self.mutex.unlock(runtime.io);
        self.emit();
    }

    pub fn writeIndex(self: *Reporter, path: []const u8, bytes: []const u8) !void {
        self.mutex.lockUncancelable(runtime.io);
        self.total = bytes.len;
        self.phase = .writing;
        self.mutex.unlock(runtime.io);
        self.emit();
        var file = try std.Io.Dir.cwd().createFileAtomic(runtime.io, path, .{ .replace = true, .make_path = true });
        defer file.deinit(runtime.io);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(offset + 1024 * 1024, bytes.len);
            try file.file.writeStreamingAll(runtime.io, bytes[offset..end]);
            offset = end;
            self.written.store(offset, .monotonic);
        }
        try file.file.sync(runtime.io);
        try file.replace(runtime.io);
        self.setPhase(.published, "");
    }

    fn emit(self: *Reporter) void {
        self.mutex.lockUncancelable(runtime.io);
        defer self.mutex.unlock(runtime.io);
        const bytes = std.json.Stringify.valueAlloc(self.allocator, .{
            .version = @as(u32, 1),
            .run_id = &self.run_id,
            .pid = std.c.getpid(),
            .started_at = self.started_at,
            .updated_at = runtime.unixTimestamp(),
            .elapsed_ms = @as(u64, @intCast(@max(0, @divTrunc(runtime.nowNanos() - self.started, std.time.ns_per_ms)))),
            .phase = @tagName(self.phase),
            .count = self.count.load(.monotonic),
            .current_path = self.current[0..self.current_len],
            .written = self.written.load(.monotonic),
            .total = self.total,
            .message = self.message,
        }, .{}) catch return;
        defer self.allocator.free(bytes);
        var file = std.Io.Dir.cwd().createFileAtomic(runtime.io, self.path, .{ .replace = true }) catch return;
        defer file.deinit(runtime.io);
        file.file.setPermissions(runtime.io, .fromMode(0o600)) catch return;
        file.file.writeStreamingAll(runtime.io, bytes) catch return;
        // Telemetry is disposable: atomic visibility matters, disk durability doesn't.
        file.replace(runtime.io) catch {};
    }
};

test "progress JSON escapes paths, records completion only after publication, and remains private" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const support = try tmp.dir.realPathFileAlloc(runtime.io, ".", allocator);
    defer allocator.free(support);
    var report = try Reporter.init(allocator, support, true);
    defer report.deinit();
    report.discovered(42, "/path/with\"quote\nand\\slash");
    report.setPhase(.building, "");
    const bytes = try runtime.readFileAlloc(allocator, report.path, .limited(65536));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("building", parsed.value.object.get("phase").?.string);
    try std.testing.expectEqual(@as(i64, 42), parsed.value.object.get("count").?.integer);
    try std.testing.expectEqual(@as(usize, 32), parsed.value.object.get("run_id").?.string.len);
    const status_file = try std.Io.Dir.openFileAbsolute(runtime.io, report.path, .{});
    defer status_file.close(runtime.io);
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), (try status_file.stat(runtime.io)).permissions.toMode() & 0o777);
    try std.testing.expectEqualStrings("/path/with\"quote\nand\\slash", parsed.value.object.get("current_path").?.string);
    const destination = try std.fs.path.join(allocator, &.{ support, "index.zst" });
    defer allocator.free(destination);
    try report.writeIndex(destination, "fixture");
    try std.testing.expectEqual(Phase.published, report.phase);
    try std.testing.expectEqual(@as(u64, 7), report.written.load(.monotonic));
}

test "telemetry failures don't fail scans and failed publication never reports success" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(runtime.io, .{ .sub_path = "not-a-directory", .data = "fixture" });
    const file = try tmp.dir.realPathFileAlloc(runtime.io, "not-a-directory", allocator);
    defer allocator.free(file);
    var report = try Reporter.init(allocator, file, false);
    defer report.deinit();
    report.setPhase(.building, "");
    const destination = try std.fs.path.join(allocator, &.{ file, "index.zst" });
    defer allocator.free(destination);
    try std.testing.expectError(error.NotDir, report.writeIndex(destination, "x"));
    try std.testing.expect(report.phase != .published);
}

test "heartbeat keeps long unchanged build phases fresh" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const support = try tmp.dir.realPathFileAlloc(runtime.io, ".", allocator);
    defer allocator.free(support);
    var report = try Reporter.init(allocator, support, true);
    defer report.deinit();
    report.discovered(123, "/fixture");
    report.setPhase(.building, "");
    report.start();
    try std.Io.sleep(runtime.io, .fromMilliseconds(1250), .awake);
    const bytes = try runtime.readFileAlloc(allocator, report.path, .limited(65536));
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("elapsed_ms").?.integer >= 900);
    try std.testing.expectEqualStrings("building", parsed.value.object.get("phase").?.string);
    try std.testing.expectEqual(@as(i64, 123), parsed.value.object.get("count").?.integer);
}
