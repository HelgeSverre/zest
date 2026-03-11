const std = @import("std");
const c = @cImport({
    @cInclude("CoreServices/CoreServices.h");
});

pub const FSEventCallback = *const fn (paths: []const []const u8) void;

pub const FSEventsWatcher = struct {
    stream: c.FSEventStreamRef,
    callback: FSEventCallback,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, watch_path: []const u8, callback: FSEventCallback) !FSEventsWatcher {
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

        // Store callback in a static so C callback can access it
        callback_storage = callback;
        allocator_storage = allocator;

        var context = c.FSEventStreamContext{
            .version = 0,
            .info = null,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };

        const stream = c.FSEventStreamCreate(
            null,
            streamCallback,
            &context,
            cf_array,
            c.kFSEventStreamEventIdSinceNow,
            2.0, // 2 second coalesce latency
            c.kFSEventStreamCreateFlagFileEvents | c.kFSEventStreamCreateFlagNoDefer,
        ) orelse return error.FSEventStreamCreateFailed;

        return .{
            .stream = stream,
            .callback = callback,
            .allocator = allocator,
        };
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

// Static storage for C callback interop
var callback_storage: ?FSEventCallback = null;
var allocator_storage: ?std.mem.Allocator = null;

fn streamCallback(
    _: c.ConstFSEventStreamRef,
    _: ?*anyopaque,
    numEvents: usize,
    eventPaths: ?*anyopaque,
    _: [*c]const c.FSEventStreamEventFlags,
    _: [*c]const c.FSEventStreamEventId,
) callconv(.C) void {
    const cb = callback_storage orelse return;
    const alloc = allocator_storage orelse return;

    const paths_ptr: [*]const [*:0]const u8 = @ptrCast(@alignCast(eventPaths));

    var path_slices = alloc.alloc([]const u8, numEvents) catch return;
    defer alloc.free(path_slices);

    for (0..numEvents) |i| {
        path_slices[i] = std.mem.span(paths_ptr[i]);
    }

    cb(path_slices);
}
