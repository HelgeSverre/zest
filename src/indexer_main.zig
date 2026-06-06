const std = @import("std");
const runtime = @import("core/runtime.zig");
pub const daemon = @import("index/daemon.zig");

pub fn main(init: std.process.Init) !void {
    runtime.init(init);
    return daemon.main(init);
}
