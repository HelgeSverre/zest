const std = @import("std");
const theme = @import("theme.zig");

// AppKit UI stub.
// Actual implementation requires zig-objc bridge for Zig 0.15.2.
// Phase 5 will implement this using direct ObjC runtime C interop.

pub fn run() !void {
    std.debug.print("AppKit UI not yet implemented. Use CLI mode.\n", .{});
}
