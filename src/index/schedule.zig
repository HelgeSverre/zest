const std = @import("std");
const second = std.time.ns_per_s;
pub const event_threshold = 1000;

/// A failed build keeps the last good index and pending work. All triggers,
/// including explicit requests and the daily safety scan, obey retry backoff.
pub const Schedule = struct {
    last_success: i128,
    pending: usize = 0,
    failures: u8 = 0,
    retry_at: i128 = 0,

    pub fn add(self: *Schedule, count: usize) void {
        self.pending +|= count;
    }

    pub fn due(self: Schedule, now: i128, requested: bool) bool {
        if (now < self.retry_at) return false;
        return self.failures > 0 or requested or self.pending >= event_threshold or
            (self.pending > 0 and now - self.last_success >= 30 * second) or
            now - self.last_success >= 24 * 3600 * second;
    }

    pub fn succeeded(self: *Schedule, now: i128) void {
        self.* = .{ .last_success = now };
    }

    pub fn failed(self: *Schedule, now: i128) void {
        self.failures +|= 1;
        const shift: u6 = @intCast(@min(self.failures - 1, 6));
        const delay = @min(@as(u64, 5) << shift, 300);
        self.retry_at = now + @as(i128, delay) * second;
    }
};

test "coalesce normal events, expedite bursts and explicit requests" {
    var s = Schedule{ .last_success = 0 };
    try std.testing.expect(!s.due(30 * second, false));
    s.add(1);
    try std.testing.expect(!s.due(29 * second, false));
    try std.testing.expect(s.due(30 * second, false));
    s.add(999);
    try std.testing.expect(s.due(second, false));
    s.succeeded(30 * second);
    try std.testing.expect(!s.due(31 * second, false));
    try std.testing.expect(s.due(31 * second, true));
}

test "failures retry without new events, cap backoff, and reset after success" {
    var s = Schedule{ .last_success = 0 };
    s.failed(0);
    try std.testing.expect(!s.due(4 * second, true));
    try std.testing.expect(s.due(5 * second, false));
    s.failed(5 * second);
    try std.testing.expect(!s.due(14 * second, false));
    try std.testing.expect(s.due(15 * second, false));
    for (0..300) |_| s.failed(0);
    try std.testing.expectEqual(@as(i128, 300 * second), s.retry_at);
    s.succeeded(400 * second);
    try std.testing.expect(!s.due(401 * second, false));
    try std.testing.expect(s.due((400 + 24 * 3600) * second, false));
}
