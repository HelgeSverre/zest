const std = @import("std");
const c = @cImport({
    // The full CoreServices umbrella pulls in `<AE/AE.h>`, which Zig 0.16's
    // translate-c cannot resolve through the nested sub-framework path.
    // Include only the pieces we need: CoreFoundation for CF types and the
    // FSEvents sub-framework directly (see the framework search path in build.zig).
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("FSEvents/FSEvents.h");
});

pub const FSEventCallback = *const fn (paths: []const []const u8) void;

pub const FSEventsWatcher = struct {
    stream: c.FSEventStreamRef,
    callback: FSEventCallback,
    allocator: std.mem.Allocator,

    /// Initialize the watcher in place. The watcher must keep a stable address
    /// for its whole lifetime: its pointer is handed to FSEvents as the stream
    /// context `info` and the C callback recovers it from there. (Previously the
    /// callback + allocator lived in module-level globals, so a second watcher
    /// clobbered the first and a callback firing after deinit read dangling
    /// state.)
    pub fn init(self: *FSEventsWatcher, allocator: std.mem.Allocator, watch_path: []const u8, callback: FSEventCallback) !void {
        // Create CFString from path
        const cf_path = c.CFStringCreateWithBytes(
            null,
            watch_path.ptr,
            @intCast(watch_path.len),
            c.kCFStringEncodingUTF8,
            0,
        ) orelse return error.CFStringCreateFailed;

        // Create CFArray with the path
        var path_ptr: ?*const anyopaque = @ptrCast(cf_path);
        const cf_array = c.CFArrayCreate(null, @ptrCast(&path_ptr), 1, &c.kCFTypeArrayCallBacks) orelse {
            c.CFRelease(@ptrCast(cf_path));
            return error.CFArrayCreateFailed;
        };
        defer c.CFRelease(@ptrCast(cf_array));
        c.CFRelease(@ptrCast(cf_path));

        self.* = .{
            .stream = undefined,
            .callback = callback,
            .allocator = allocator,
        };

        // Pass the watcher through the per-stream context so the callback can
        // recover its own state instead of reaching for a global.
        var context = c.FSEventStreamContext{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };

        self.stream = c.FSEventStreamCreate(
            null,
            streamCallback,
            &context,
            cf_array,
            c.kFSEventStreamEventIdSinceNow,
            2.0, // 2 second coalesce latency
            c.kFSEventStreamCreateFlagFileEvents | c.kFSEventStreamCreateFlagNoDefer,
        ) orelse return error.FSEventStreamCreateFailed;
    }

    pub fn start(self: *FSEventsWatcher) void {
        c.FSEventStreamScheduleWithRunLoop(
            self.stream,
            c.CFRunLoopGetCurrent(),
            c.kCFRunLoopDefaultMode,
        );
        _ = c.FSEventStreamStart(self.stream);
    }

    pub fn stop(self: *FSEventsWatcher) void {
        c.FSEventStreamStop(self.stream);
        c.FSEventStreamInvalidate(self.stream);
    }

    pub fn deinit(self: *FSEventsWatcher) void {
        c.FSEventStreamRelease(self.stream);
    }
};

fn streamCallback(
    _: c.ConstFSEventStreamRef,
    info: ?*anyopaque,
    numEvents: usize,
    eventPaths: ?*anyopaque,
    _: [*c]const c.FSEventStreamEventFlags,
    _: [*c]const c.FSEventStreamEventId,
) callconv(.c) void {
    const self: *FSEventsWatcher = @ptrCast(@alignCast(info orelse return));
    const cb = self.callback;
    const alloc = self.allocator;

    const paths_ptr: [*]const [*:0]const u8 = @ptrCast(@alignCast(eventPaths));

    var path_slices = alloc.alloc([]const u8, numEvents) catch return;
    defer alloc.free(path_slices);

    for (0..numEvents) |i| {
        path_slices[i] = std.mem.span(paths_ptr[i]);
    }

    cb(path_slices);
}
