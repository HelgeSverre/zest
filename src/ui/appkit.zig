const objc = @import("objc.zig");
const delegate = @import("delegate.zig");
const std = @import("std");
const App = @import("../app.zig").App;

pub fn run(allocator: std.mem.Allocator, app: *App) !void {
    // Autorelease pool for setup
    const pool = objc.init(objc.alloc(objc.getClass("NSAutoreleasePool") orelse return error.AppKitNotAvailable));
    defer objc.msgSendVoid(pool, "drain");

    // Get shared NSApplication
    const NSApp = objc.msgSend(objc.getClass("NSApplication") orelse return error.AppKitNotAvailable, "sharedApplication");

    // Activation policy MUST be set before delegate/finishLaunching for non-bundled apps
    // NSApplicationActivationPolicyRegular = 0 — gives us Dock icon and menu bar
    objc.msgSendVoidWith1(i64, NSApp, "setActivationPolicy:", @as(i64, 0));

    // Register all ObjC delegate classes
    delegate.registerAllClasses();

    // Create AppState
    const app_state = try allocator.create(delegate.AppState);
    app_state.* = .{
        .app = app,
        .allocator = allocator,
    };
    delegate.state = app_state;

    // Create and set app delegate
    const app_delegate_cls = objc.getClass("ZestAppDelegate") orelse return error.ClassNotRegistered;
    const app_delegate = objc.init(objc.alloc(app_delegate_cls));
    objc.msgSendVoidWith1(objc.id, NSApp, "setDelegate:", app_delegate);

    // Run the event loop (blocks until app quits)
    // [NSApp run] calls finishLaunching which triggers applicationDidFinishLaunching:
    // where the window is created — activation happens there
    objc.msgSendVoid(NSApp, "run");

    // Cleanup
    app_state.deinit();
    allocator.destroy(app_state);
    delegate.state = null;
}
