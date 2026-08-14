//! Length-preserving simple case folding for UTF-8.
//!
//! The index stores a lowercase name blob that is *byte-parallel* to the
//! original blob: the same `(offset, length)` pair addresses a name in both, so
//! a match found in the lowercase blob maps back to an entry by binary search
//! over the shared offsets (see `index/search.zig`). Folding must therefore
//! never change a name's byte length.
//!
//! Every mapping here keeps the UTF-8 encoded length identical (the ranges are
//! chosen so a codepoint never crosses the 0x80 / 0x800 / 0x10000 boundaries),
//! and `foldInto` verifies that invariant at runtime — a mapping that would
//! change the length copies the original bytes through instead. Codepoints
//! whose lowercase form is a different length (İ U+0130 → "i̇", ẞ U+1E9E → ß,
//! K U+212A → k, ſ U+017F → s) are deliberately left unfolded: they stay
//! searchable by their own bytes rather than corrupting the blob's geometry.
//!
//! Case-*folding* rather than strict lowercasing in one place: final sigma
//! (ς U+03C2) folds to σ so "ΟΔΟΣ", "οδος" and "οδός"-style variants match.
//!
//! Invalid UTF-8 (filenames are just bytes on macOS) is passed through
//! byte-for-byte; decoding never fails.
const std = @import("std");

/// Fold `src` into `dst`, writing exactly `src.len` bytes.
/// `dst.len` must be >= `src.len`; only the first `src.len` bytes are touched.
pub fn foldInto(dst: []u8, src: []const u8) void {
    std.debug.assert(dst.len >= src.len);
    var i: usize = 0;
    while (i < src.len) {
        const b = src[i];
        // ASCII fast path — the overwhelming majority of filename bytes.
        if (b < 0x80) {
            dst[i] = std.ascii.toLower(b);
            i += 1;
            continue;
        }
        const seq_len = sequenceLength(b) orelse {
            dst[i] = b;
            i += 1;
            continue;
        };
        if (i + seq_len > src.len or !isContinuation(src[i..][0..seq_len])) {
            dst[i] = b;
            i += 1;
            continue;
        }
        const cp = decode(src[i..][0..seq_len]);
        const folded = foldCodepoint(cp);
        // The length check makes a mistaken table entry a no-op instead of a
        // blob-corrupting write; `fold never changes encoded length` pins it.
        if (folded != cp and encodedLength(folded) == seq_len) {
            encode(dst[i..][0..seq_len], folded);
        } else {
            @memcpy(dst[i..][0..seq_len], src[i..][0..seq_len]);
        }
        i += seq_len;
    }
}

/// Simple case fold of a single codepoint, restricted to mappings that keep
/// the UTF-8 encoded length. Unmapped codepoints are returned unchanged.
pub fn foldCodepoint(cp: u21) u21 {
    if (cp < 0x80) return if (cp >= 'A' and cp <= 'Z') cp + 32 else cp;
    return switch (cp) {
        // Latin-1 Supplement: À-Þ (0xD7 is ×, not a letter) -> à-þ.
        0xC0...0xD6, 0xD8...0xDE => cp + 0x20,

        // Latin Extended-A / B: blocks of (even = upper, odd = lower) pairs.
        // U+0130 (İ) is the one hole in the first block — its lowercase is "i",
        // not the dotless ı that the even/odd rule would produce.
        0x100...0x12F,
        0x131...0x137,
        0x14A...0x177,
        0x1DE...0x1EF,
        0x1F8...0x21F,
        0x222...0x233,
        0x246...0x24F,
        0x3D8...0x3EF,
        0x460...0x481,
        0x48A...0x4BF,
        0x4D0...0x52F,
        0x1E00...0x1E95,
        0x1EA0...0x1EFF,
        => cp | 1,

        // ...and blocks where the pairs are offset by one (odd = upper).
        0x139...0x148,
        0x179...0x17E,
        0x1CD...0x1DC,
        0x4C1...0x4CE,
        => if (cp & 1 == 1) cp + 1 else cp,

        0x178 => 0xFF, // Ÿ -> ÿ

        // Greek.
        0x386 => 0x3AC,
        0x388...0x38A => cp + 0x25,
        0x38C => 0x3CC,
        0x38E...0x38F => cp + 0x3F,
        0x391...0x3A1, 0x3A3...0x3AB => cp + 0x20,
        0x3C2 => 0x3C3, // final sigma folds to sigma

        // Cyrillic.
        0x400...0x40F => cp + 0x50,
        0x410...0x42F => cp + 0x20,

        // Armenian.
        0x531...0x556 => cp + 0x30,

        // Greek Extended: the regular "uppercase sits 8 above lowercase" runs.
        0x1F08...0x1F0F,
        0x1F18...0x1F1D,
        0x1F28...0x1F2F,
        0x1F38...0x1F3F,
        0x1F48...0x1F4D,
        0x1F68...0x1F6F,
        0x1F88...0x1F8F,
        0x1F98...0x1F9F,
        0x1FA8...0x1FAF,
        => cp - 8,

        // Fullwidth Latin.
        0xFF21...0xFF3A => cp + 0x20,

        else => cp,
    };
}

/// Fold an extension-sized ASCII-or-UTF-8 slice into a fixed buffer, returning
/// the folded slice. Convenience for the `ext:` paths, which compare a folded
/// query value against a folded on-disk value.
pub fn foldSlice(buf: []u8, src: []const u8) []const u8 {
    const n = @min(buf.len, src.len);
    foldInto(buf[0..n], src[0..n]);
    return buf[0..n];
}

// --- minimal UTF-8 codec (std's decoder returns errors we'd only swallow) ---

fn sequenceLength(first: u8) ?u3 {
    return switch (first) {
        0x00...0x7F => 1,
        0xC2...0xDF => 2,
        0xE0...0xEF => 3,
        0xF0...0xF4 => 4,
        else => null, // continuation byte or overlong/invalid lead
    };
}

fn isContinuation(rest: []const u8) bool {
    for (rest[1..]) |b| {
        if (b & 0xC0 != 0x80) return false;
    }
    return rest.len > 0;
}

fn decode(bytes: []const u8) u21 {
    return switch (bytes.len) {
        2 => (@as(u21, bytes[0] & 0x1F) << 6) | (bytes[1] & 0x3F),
        3 => (@as(u21, bytes[0] & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | (bytes[2] & 0x3F),
        4 => (@as(u21, bytes[0] & 0x07) << 18) | (@as(u21, bytes[1] & 0x3F) << 12) |
            (@as(u21, bytes[2] & 0x3F) << 6) | (bytes[3] & 0x3F),
        else => bytes[0],
    };
}

fn encode(dst: []u8, cp: u21) void {
    switch (dst.len) {
        2 => {
            dst[0] = @intCast(0xC0 | (cp >> 6));
            dst[1] = @intCast(0x80 | (cp & 0x3F));
        },
        3 => {
            dst[0] = @intCast(0xE0 | (cp >> 12));
            dst[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            dst[2] = @intCast(0x80 | (cp & 0x3F));
        },
        4 => {
            dst[0] = @intCast(0xF0 | (cp >> 18));
            dst[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
            dst[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            dst[3] = @intCast(0x80 | (cp & 0x3F));
        },
        else => dst[0] = @intCast(cp),
    }
}

fn encodedLength(cp: u21) u3 {
    if (cp < 0x80) return 1;
    if (cp < 0x800) return 2;
    if (cp < 0x10000) return 3;
    return 4;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn fold(comptime src: []const u8) [src.len]u8 {
    var out: [src.len]u8 = undefined;
    foldInto(&out, src);
    return out;
}

test "ascii folds like std.ascii.toLower" {
    var i: u16 = 0;
    while (i < 128) : (i += 1) {
        const b: u8 = @intCast(i);
        var out: [1]u8 = undefined;
        foldInto(&out, &[_]u8{b});
        try std.testing.expectEqual(std.ascii.toLower(b), out[0]);
    }
}

test "fold never changes encoded length" {
    // The blob's geometry depends on this for every codepoint, not just the
    // ones the tests below name.
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue; // surrogates
        const folded = foldCodepoint(cp);
        try std.testing.expectEqual(encodedLength(cp), encodedLength(folded));
    }
}

test "fold is idempotent" {
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        const once = foldCodepoint(cp);
        try std.testing.expectEqual(once, foldCodepoint(once));
    }
}

test "foldInto writes exactly src.len bytes and folds stably" {
    const cases = [_][]const u8{
        "Résumé.PDF",
        "ÜBERSICHT",
        "ΕΛΛΑΔΑ",
        "МОСКВА",
        "ԱՐՄԵՆԻԱ",
        "İstanbul",
        "STRAẞE",
        "K",
        "ſtraße",
        "ＦＵＬＬＷＩＤＴＨ",
        "a\xc3",
        "\xff\xfe broken",
        "",
        "plain",
    };
    for (cases) |c| {
        var buf: [64]u8 = undefined;
        @memset(&buf, 0xAA);
        foldInto(&buf, c);
        // Nothing past the input length may be touched — the blob packs names
        // back to back, so an overrun would corrupt the next name.
        for (buf[c.len..]) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);

        var again: [64]u8 = undefined;
        foldInto(&again, buf[0..c.len]);
        try std.testing.expectEqualSlices(u8, buf[0..c.len], again[0..c.len]);
    }
}

test "latin-1 and latin extended fold" {
    try std.testing.expectEqualSlices(u8, "résumé", &fold("RÉSUMÉ"));
    try std.testing.expectEqualSlices(u8, "übersicht", &fold("ÜBERSICHT"));
    try std.testing.expectEqualSlices(u8, "cœur", &fold("CŒUR"));
    try std.testing.expectEqualSlices(u8, "łódź", &fold("ŁÓDŹ"));
    try std.testing.expectEqualSlices(u8, "ÿ", &fold("Ÿ"));
    // × (U+00D7) is multiplication, not a letter — must not shift to ÷.
    try std.testing.expectEqualSlices(u8, "×", &fold("×"));
}

test "greek cyrillic armenian fold" {
    try std.testing.expectEqualSlices(u8, "ελλάδα", &fold("ΕΛΛΆΔΑ"));
    try std.testing.expectEqualSlices(u8, "москва", &fold("МОСКВА"));
    try std.testing.expectEqualSlices(u8, "ёжик", &fold("ЁЖИК"));
    try std.testing.expectEqualSlices(u8, "հայերեն", &fold("ՀԱՅԵՐԵՆ"));
    // Final sigma folds to plain sigma, so "ΟΔΟΣ" and "οδος" (which ends in
    // ς, U+03C2) collapse to the same folded form and match one query.
    try std.testing.expectEqualSlices(u8, "οδοσ", &fold("ΟΔΟΣ"));
    try std.testing.expectEqualSlices(u8, "οδοσ", &fold("οδος"));
}

test "vietnamese and fullwidth fold" {
    try std.testing.expectEqualSlices(u8, "tiếng việt", &fold("TIẾNG VIỆT"));
    try std.testing.expectEqualSlices(u8, "ｆｕｌｌ", &fold("ＦＵＬＬ"));
}

test "length-changing mappings are left alone" {
    // ẞ -> ß, K (Kelvin) -> k, ſ -> s and İ -> i̇ all shrink; folding them
    // would desynchronize the blob, so they must pass through untouched.
    try std.testing.expectEqualSlices(u8, "\u{1E9E}", &fold("\u{1E9E}")); // ẞ
    try std.testing.expectEqualSlices(u8, "\u{212A}", &fold("\u{212A}")); // KELVIN SIGN
    try std.testing.expectEqualSlices(u8, "\u{017F}", &fold("\u{017F}")); // ſ
    try std.testing.expectEqualSlices(u8, "\u{0130}", &fold("\u{0130}")); // İ
}

test "invalid utf-8 passes through unchanged" {
    const bad = [_]u8{ 'A', 0xFF, 0xC3, 'B', 0x80, 0xE2, 0x82 };
    var out: [bad.len]u8 = undefined;
    foldInto(&out, &bad);
    try std.testing.expectEqual(@as(u8, 'a'), out[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), out[1]);
    // 0xC3 without a valid continuation stays as-is; 'B' still folds.
    try std.testing.expectEqual(@as(u8, 0xC3), out[2]);
    try std.testing.expectEqual(@as(u8, 'b'), out[3]);
    try std.testing.expectEqual(@as(u8, 0x80), out[4]);
    try std.testing.expectEqual(@as(u8, 0xE2), out[5]);
    try std.testing.expectEqual(@as(u8, 0x82), out[6]);
}

test "foldSlice caps at the destination buffer" {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", foldSlice(&buf, "ABCDEF"));
    try std.testing.expectEqualStrings("ab", foldSlice(&buf, "AB"));
}
