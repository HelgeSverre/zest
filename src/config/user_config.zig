//! Terminal-preference helpers for the "Open in Terminal" action.
//! This module owns the candidate-list policy for terminal detection.

const std = @import("std");

/// Terminal apps tried (in order) when no configured terminal launches.
/// `open -a <name>` exits non-zero *without* launching when the app is absent,
/// so Terminal.app (always installed, listed last) is the guaranteed fallback.
pub const default_terminals = [_][]const u8{ "iTerm", "Ghostty", "WezTerm", "kitty", "Alacritty", "Terminal" };

/// Maximum candidates `terminalCandidates` can produce (configured + defaults).
pub const max_candidates = default_terminals.len + 1;

/// Build the ordered, de-duplicated candidate list: the configured terminal
/// (if any, non-empty) first, then the defaults. `out` must hold at least
/// `max_candidates` entries. Returned slices alias `configured`/`default_terminals`.
pub fn terminalCandidates(out: [][]const u8, configured: ?[]const u8) [][]const u8 {
    var count: usize = 0;
    if (configured) |c| {
        if (c.len > 0) {
            out[count] = c;
            count += 1;
        }
    }
    for (default_terminals) |d| {
        var dup = false;
        for (out[0..count]) |existing| {
            if (std.mem.eql(u8, existing, d)) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            out[count] = d;
            count += 1;
        }
    }
    return out[0..count];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "terminalCandidates without config is the default order" {
    var buf: [max_candidates][]const u8 = undefined;
    const got = terminalCandidates(&buf, null);
    try std.testing.expectEqual(@as(usize, 6), got.len);
    try std.testing.expectEqualStrings("iTerm", got[0]);
    try std.testing.expectEqualStrings("Terminal", got[5]);
}

test "terminalCandidates puts a new configured terminal first" {
    var buf: [max_candidates][]const u8 = undefined;
    const got = terminalCandidates(&buf, "Warp");
    try std.testing.expectEqual(@as(usize, 7), got.len);
    try std.testing.expectEqualStrings("Warp", got[0]);
    try std.testing.expectEqualStrings("Terminal", got[6]);
}

test "terminalCandidates de-duplicates a configured default" {
    var buf: [max_candidates][]const u8 = undefined;
    const got = terminalCandidates(&buf, "iTerm");
    try std.testing.expectEqual(@as(usize, 6), got.len);
    try std.testing.expectEqualStrings("iTerm", got[0]);
    // iTerm should not appear twice.
    var seen: usize = 0;
    for (got) |c| {
        if (std.mem.eql(u8, c, "iTerm")) seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "terminalCandidates skips an empty configured string" {
    var buf: [max_candidates][]const u8 = undefined;
    const got = terminalCandidates(&buf, "");
    try std.testing.expectEqual(@as(usize, 6), got.len);
    try std.testing.expectEqualStrings("iTerm", got[0]);
}

test "terminalCandidates keeps Terminal.app last as fallback" {
    var buf: [max_candidates][]const u8 = undefined;
    const got = terminalCandidates(&buf, "Terminal");
    try std.testing.expectEqual(@as(usize, 6), got.len);
    try std.testing.expectEqualStrings("Terminal", got[0]);
    // Still de-duplicated to 6 (Terminal not repeated).
    try std.testing.expectEqualStrings("Alacritty", got[5]);
}
