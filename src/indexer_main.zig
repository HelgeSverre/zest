pub const daemon = @import("index/daemon.zig");

pub fn main() !void {
    return daemon.main();
}
