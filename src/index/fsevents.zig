const std = @import("std");
pub const c = @cImport({
    @cInclude("fsevents_bridge.h");
});
pub const FSEventCallback = *const fn (paths: []const []const u8, must_rescan: bool) void;

pub const FSEventsWatcher = struct {
    stream: *anyopaque,
    callback: FSEventCallback,
    allocator: std.mem.Allocator,

    /// Keep this struct at a stable address for the stream context's lifetime.
    pub fn init(self: *FSEventsWatcher, allocator: std.mem.Allocator, watch_path: []const u8, exclude_paths: []const []const u8, callback: FSEventCallback) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        const root = try temporary.dupeZ(u8, watch_path);
        const excludes = try temporary.alloc([*:0]const u8, exclude_paths.len);
        for (exclude_paths, 0..) |path, i| excludes[i] = try temporary.dupeZ(u8, path);
        self.* = .{ .stream = undefined, .callback = callback, .allocator = allocator };
        self.stream = c.zest_events_create(root.ptr, @ptrCast(excludes.ptr), excludes.len, streamCallback, self) orelse return error.FSEventStreamCreateFailed;
    }

    pub fn start(self: *FSEventsWatcher) !void {
        if (!c.zest_events_start(self.stream)) return error.FSEventStreamStartFailed;
    }
    pub fn stop(self: *FSEventsWatcher) void {
        c.zest_events_stop(self.stream);
    }
    pub fn deinit(self: *FSEventsWatcher) void {
        c.zest_events_destroy(self.stream);
    }
};

fn streamCallback(info: ?*anyopaque, count: usize, paths: [*c]const [*c]const u8, rescan: bool) callconv(.c) void {
    const self: *FSEventsWatcher = @ptrCast(@alignCast(info orelse return));
    const slices = self.allocator.alloc([]const u8, count) catch {
        self.callback(&.{}, true);
        return;
    };
    defer self.allocator.free(slices);
    for (slices, 0..) |*slice, i| slice.* = std.mem.span(paths[i]);
    self.callback(slices, rescan);
}
