#include "fsevents_bridge.h"
#include <CoreFoundation/CoreFoundation.h>
#include <FSEvents/FSEvents.h>
#include <stdlib.h>

typedef struct {
    FSEventStreamRef stream;
    zest_events_callback callback;
    void *context;
    bool started;
} ZestEvents;

static void events(ConstFSEventStreamRef stream, void *info, size_t count,
                   void *paths, const FSEventStreamEventFlags flags[],
                   const FSEventStreamEventId ids[]) {
    (void)stream; (void)ids;
    ZestEvents *watcher = info;
    bool rescan = false;
    for (size_t i = 0; i < count; ++i) {
        if (flags[i] & (kFSEventStreamEventFlagUserDropped |
                        kFSEventStreamEventFlagKernelDropped |
                        kFSEventStreamEventFlagRootChanged)) rescan = true;
    }
    watcher->callback(watcher->context, count, paths, rescan);
}

void *zest_events_create(const char *root, const char *const *excludes, size_t count,
                        zest_events_callback callback, void *context) {
    if (count > 8) return NULL;
    ZestEvents *watcher = calloc(1, sizeof(*watcher));
    if (!watcher) return NULL;
    watcher->callback = callback;
    watcher->context = context;
    CFStringRef path = CFStringCreateWithCString(NULL, root, kCFStringEncodingUTF8);
    if (!path) { free(watcher); return NULL; }
    CFArrayRef paths = CFArrayCreate(NULL, (const void **)&path, 1, &kCFTypeArrayCallBacks);
    CFRelease(path);
    if (!paths) { free(watcher); return NULL; }
    FSEventStreamContext streamContext = {0, watcher, NULL, NULL, NULL};
    watcher->stream = FSEventStreamCreate(NULL, events, &streamContext, paths,
        kFSEventStreamEventIdSinceNow, 2.0,
        /* Directory-level events: each path is a directory whose contents
         * changed, coalesced by the kernel. That is exactly the unit the
         * incremental rebuild relists, and far fewer events than FileEvents. */
        kFSEventStreamCreateFlagNoDefer |
        kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagWatchRoot);
    CFRelease(paths);
    if (!watcher->stream) { free(watcher); return NULL; }
    if (count) {
        CFMutableArrayRef array = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        if (!array) { zest_events_destroy(watcher); return NULL; }
        for (size_t i = 0; i < count; ++i) {
            CFStringRef exclude = CFStringCreateWithCString(NULL, excludes[i], kCFStringEncodingUTF8);
            if (!exclude) { CFRelease(array); zest_events_destroy(watcher); return NULL; }
            CFArrayAppendValue(array, exclude);
            CFRelease(exclude);
        }
        bool ok = FSEventStreamSetExclusionPaths(watcher->stream, array);
        CFRelease(array);
        if (!ok) { zest_events_destroy(watcher); return NULL; }
    }
    return watcher;
}

bool zest_events_start(void *handle) {
    ZestEvents *watcher = handle;
    FSEventStreamScheduleWithRunLoop(watcher->stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    watcher->started = FSEventStreamStart(watcher->stream);
    if (!watcher->started) FSEventStreamInvalidate(watcher->stream);
    return watcher->started;
}
void zest_events_stop(void *handle) {
    ZestEvents *watcher = handle;
    if (!watcher->started) return;
    FSEventStreamStop(watcher->stream);
    FSEventStreamInvalidate(watcher->stream);
    watcher->started = false;
}
void zest_events_destroy(void *handle) {
    ZestEvents *watcher = handle;
    zest_events_stop(handle);
    FSEventStreamRelease(watcher->stream);
    free(watcher);
}
void zest_run_loop_stop(void) { CFRunLoopStop(CFRunLoopGetCurrent()); }
void zest_run_loop_run(double seconds) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false); }
