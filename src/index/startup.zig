const std = @import("std");

/// Run daemon startup in the only safe order: begin observing changes before
/// the initial scan, then enter the event loop. Errors stop later phases.
pub fn run(ops: anytype) !void {
    try ops.startWatcher();
    try ops.initialScan();
    try ops.watchLoop();
}

const Recorder = struct {
    log: std.ArrayList(u8) = .empty,
    fail_watcher: bool = false,
    fail_scan: bool = false,

    fn deinit(self: *Recorder) void {
        self.log.deinit(std.testing.allocator);
    }

    fn record(self: *Recorder, name: []const u8) !void {
        if (self.log.items.len > 0) try self.log.append(std.testing.allocator, ',');
        try self.log.appendSlice(std.testing.allocator, name);
    }

    pub fn startWatcher(self: *Recorder) !void {
        try self.record("watcher");
        if (self.fail_watcher) return error.WatcherFailed;
    }

    pub fn initialScan(self: *Recorder) !void {
        try self.record("scan");
        if (self.fail_scan) return error.ScanFailed;
    }

    pub fn watchLoop(self: *Recorder) !void {
        try self.record("loop");
    }
};

test "startup starts watcher before scanning and entering the loop" {
    var recorder = Recorder{};
    defer recorder.deinit();

    try run(&recorder);

    try std.testing.expectEqualStrings("watcher,scan,loop", recorder.log.items);
}

test "startup stops when watcher start fails" {
    var recorder = Recorder{ .fail_watcher = true };
    defer recorder.deinit();

    try std.testing.expectError(error.WatcherFailed, run(&recorder));

    try std.testing.expectEqualStrings("watcher", recorder.log.items);
}

test "startup does not enter watch loop when initial scan fails" {
    var recorder = Recorder{ .fail_scan = true };
    defer recorder.deinit();

    try std.testing.expectError(error.ScanFailed, run(&recorder));

    try std.testing.expectEqualStrings("watcher,scan", recorder.log.items);
}
