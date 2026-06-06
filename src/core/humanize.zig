//! Tiny human-friendly formatters for log/CLI output (byte sizes, durations,
//! grouped integers). Integer-only math — no float formatting — and each writes
//! into a caller-provided buffer, returning the filled slice.

const std = @import("std");

/// Format a byte count like "506.9 MiB" (binary units). Needs a ~16-byte buffer.
pub fn bytes(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB", "PiB" };
    var whole: u64 = n;
    var rem: u64 = 0;
    var unit: usize = 0;
    while (whole >= 1024 and unit < units.len - 1) : (unit += 1) {
        rem = whole % 1024;
        whole /= 1024;
    }
    if (unit == 0) return std.fmt.bufPrint(buf, "{d} B", .{whole}) catch return "?";
    const frac = rem * 10 / 1024; // one decimal digit
    return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ whole, frac, units[unit] }) catch return "?";
}

/// Format a millisecond duration like "850ms", "24.9s", or "1m 05s". Needs a
/// ~16-byte buffer.
pub fn duration(buf: []u8, ms_in: i128) []const u8 {
    const ms: u64 = @intCast(@max(@as(i128, 0), ms_in));
    if (ms < 1000) return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch return "?";
    const total_s = ms / 1000;
    if (total_s < 60) {
        const frac = (ms % 1000) / 100; // one decimal digit
        return std.fmt.bufPrint(buf, "{d}.{d}s", .{ total_s, frac }) catch return "?";
    }
    const s = total_s % 60;
    return std.fmt.bufPrint(buf, "{d}m {d}{d}s", .{ total_s / 60, s / 10, s % 10 }) catch return "?";
}

/// Format an integer with thousands separators ("5,704,872"). Needs a ~32-byte buffer.
pub fn count(buf: []u8, n: u64) []const u8 {
    var digits_buf: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{n}) catch return "?";
    var out: usize = 0;
    for (digits, 0..) |ch, i| {
        if (i > 0 and (digits.len - i) % 3 == 0) {
            if (out >= buf.len) break;
            buf[out] = ',';
            out += 1;
        }
        if (out >= buf.len) break;
        buf[out] = ch;
        out += 1;
    }
    return buf[0..out];
}

test "humanize.bytes" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", bytes(&b, 0));
    try std.testing.expectEqualStrings("512 B", bytes(&b, 512));
    try std.testing.expectEqualStrings("1.0 KiB", bytes(&b, 1024));
    try std.testing.expectEqualStrings("506.9 MiB", bytes(&b, 531615807));
}

test "humanize.duration" {
    var b: [16]u8 = undefined;
    try std.testing.expectEqualStrings("850ms", duration(&b, 850));
    try std.testing.expectEqualStrings("24.9s", duration(&b, 24935));
    try std.testing.expectEqualStrings("2.2s", duration(&b, 2278));
    try std.testing.expectEqualStrings("1m 05s", duration(&b, 65000));
}

test "humanize.count" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0", count(&b, 0));
    try std.testing.expectEqualStrings("999", count(&b, 999));
    try std.testing.expectEqualStrings("5,704,872", count(&b, 5704872));
}
