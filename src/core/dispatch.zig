const std = @import("std");

const dispatch_c = @cImport({
    @cInclude("dispatch/dispatch.h");
});

pub const dispatch_queue_t = *anyopaque;
pub const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;

// libdispatch exports the main queue as the global symbol `_dispatch_main_q`.
// The C header types it as an opaque struct, which Zig 0.16's translate-c
// surfaces as an opaque type we cannot take the address of. Re-declare the
// symbol with a sized type so we can obtain its address; only the address
// matters, and the linker resolves it by name.
extern var _dispatch_main_q: usize;

/// Returns the main dispatch queue (runs on the AppKit main thread).
pub fn dispatch_get_main_queue() dispatch_queue_t {
    return @ptrCast(&_dispatch_main_q);
}

/// Schedule `work(context)` to run asynchronously on `queue`.
/// Uses the _f variant (C function pointer) since Zig cannot create ObjC blocks.
pub fn dispatch_async_f(queue: dispatch_queue_t, context: ?*anyopaque, work: dispatch_function_t) void {
    dispatch_c.dispatch_async_f(@ptrCast(queue), context, work);
}
