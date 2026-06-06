const std = @import("std");
const types = @import("types.zig");
const runtime = @import("runtime.zig");

pub const CompareOp = enum {
    eq,
    gt,
    lt,
    gte,
    lte,
    range,
};

pub const FilterCriterion = union(enum) {
    kind: struct { negated: bool = false, value: types.FileKind },
    extension: struct { negated: bool = false, value: [32]u8 = .{0} ** 32, len: u8 = 0 },
    size: struct { op: CompareOp = .eq, value: u64 = 0, value_upper: u64 = 0 },
    date: struct { op: CompareOp = .eq, value: i64 = 0, value_upper: i64 = 0 },
    category: struct { negated: bool = false, value: types.FileCategory },
    path: struct { negated: bool = false, value: [255]u8 = .{0} ** 255, len: u8 = 0 },

    pub fn matches(self: FilterCriterion, result: MatchTarget) bool {
        return switch (self) {
            .kind => |f| {
                const m = result.kind == f.value;
                return if (f.negated) !m else m;
            },
            .extension => |f| {
                const ext_str = f.value[0..f.len];
                const name = result.name;
                // Find last '.' in name
                const dot_pos = std.mem.lastIndexOfScalar(u8, name, '.') orelse return f.negated;
                const file_ext = name[dot_pos + 1 ..];
                const m = std.ascii.eqlIgnoreCase(file_ext, ext_str);
                return if (f.negated) !m else m;
            },
            .size => |f| matchNumeric(f.op, result.size, f.value, f.value_upper),
            .date => |f| matchNumericSigned(f.op, result.mtime, f.value, f.value_upper),
            .category => |f| {
                const m = result.category == f.value;
                return if (f.negated) !m else m;
            },
            .path => |f| {
                const path_str = f.value[0..f.len];
                const dir = result.dir_path;
                const m = std.mem.indexOf(u8, dir, path_str) != null;
                return if (f.negated) !m else m;
            },
        };
    }
};

pub const MatchTarget = struct {
    name: []const u8 = "",
    dir_path: []const u8 = "",
    size: u64 = 0,
    mtime: i64 = 0,
    kind: types.FileKind = .file,
    category: types.FileCategory = .uncategorized,
};

pub fn matchesAll(criteria: []const FilterCriterion, target: MatchTarget) bool {
    for (criteria) |c| {
        if (!c.matches(target)) return false;
    }
    return true;
}

fn matchNumeric(op: CompareOp, actual: u64, expected: u64, upper: u64) bool {
    return switch (op) {
        .eq => actual == expected,
        .gt => actual > expected,
        .lt => actual < expected,
        .gte => actual >= expected,
        .lte => actual <= expected,
        .range => actual >= expected and actual <= upper,
    };
}

fn matchNumericSigned(op: CompareOp, actual: i64, expected: i64, upper: i64) bool {
    return switch (op) {
        .eq => actual == expected,
        .gt => actual > expected,
        .lt => actual < expected,
        .gte => actual >= expected,
        .lte => actual <= expected,
        .range => actual >= expected and actual <= upper,
    };
}

/// Parse a size string like "1mb", "500kb", "2gb" into bytes.
pub fn parseSize(input: []const u8) !u64 {
    if (input.len == 0) return error.InvalidSize;

    // Find where digits end
    var num_end: usize = 0;
    var has_dot = false;
    for (input) |ch| {
        if (std.ascii.isDigit(ch)) {
            num_end += 1;
        } else if (ch == '.' and !has_dot) {
            has_dot = true;
            num_end += 1;
        } else break;
    }
    if (num_end == 0) return error.InvalidSize;

    const num_str = input[0..num_end];
    const suffix = input[num_end..];

    if (has_dot) {
        const value = std.fmt.parseFloat(f64, num_str) catch return error.InvalidSize;
        const multiplier: f64 = sizeMultiplier(suffix) orelse return error.InvalidSize;
        return @intFromFloat(value * multiplier);
    }

    const value = std.fmt.parseInt(u64, num_str, 10) catch return error.InvalidSize;
    const multiplier = sizeMultiplierInt(suffix) orelse return error.InvalidSize;
    return value * multiplier;
}

fn sizeMultiplier(suffix: []const u8) ?f64 {
    if (suffix.len == 0 or std.ascii.eqlIgnoreCase(suffix, "b")) return 1.0;
    if (std.ascii.eqlIgnoreCase(suffix, "kb") or std.ascii.eqlIgnoreCase(suffix, "k")) return 1024.0;
    if (std.ascii.eqlIgnoreCase(suffix, "mb") or std.ascii.eqlIgnoreCase(suffix, "m")) return 1024.0 * 1024.0;
    if (std.ascii.eqlIgnoreCase(suffix, "gb") or std.ascii.eqlIgnoreCase(suffix, "g")) return 1024.0 * 1024.0 * 1024.0;
    if (std.ascii.eqlIgnoreCase(suffix, "tb") or std.ascii.eqlIgnoreCase(suffix, "t")) return 1024.0 * 1024.0 * 1024.0 * 1024.0;
    return null;
}

fn sizeMultiplierInt(suffix: []const u8) ?u64 {
    if (suffix.len == 0 or std.ascii.eqlIgnoreCase(suffix, "b")) return 1;
    if (std.ascii.eqlIgnoreCase(suffix, "kb") or std.ascii.eqlIgnoreCase(suffix, "k")) return 1024;
    if (std.ascii.eqlIgnoreCase(suffix, "mb") or std.ascii.eqlIgnoreCase(suffix, "m")) return 1024 * 1024;
    if (std.ascii.eqlIgnoreCase(suffix, "gb") or std.ascii.eqlIgnoreCase(suffix, "g")) return 1024 * 1024 * 1024;
    if (std.ascii.eqlIgnoreCase(suffix, "tb") or std.ascii.eqlIgnoreCase(suffix, "t")) return 1024 * 1024 * 1024 * 1024;
    return null;
}

/// Parse a date string into a unix timestamp.
/// Supports: "today", "week", "month", "year", ">YYYY-MM-DD", "<YYYY-MM-DD", "YYYY-MM-DD..YYYY-MM-DD"
pub fn parseDate(input: []const u8) !DateResult {
    const now = runtime.unixTimestamp();
    const day_secs: i64 = 86400;

    if (std.ascii.eqlIgnoreCase(input, "today")) {
        return .{ .op = .gte, .value = now - day_secs, .value_upper = 0 };
    }
    if (std.ascii.eqlIgnoreCase(input, "week")) {
        return .{ .op = .gte, .value = now - 7 * day_secs, .value_upper = 0 };
    }
    if (std.ascii.eqlIgnoreCase(input, "month")) {
        return .{ .op = .gte, .value = now - 30 * day_secs, .value_upper = 0 };
    }
    if (std.ascii.eqlIgnoreCase(input, "year")) {
        return .{ .op = .gte, .value = now - 365 * day_secs, .value_upper = 0 };
    }

    // Range: YYYY-MM-DD..YYYY-MM-DD
    if (std.mem.indexOf(u8, input, "..")) |sep| {
        const lower = parseDateString(input[0..sep]) catch return error.InvalidDate;
        const upper = parseDateString(input[sep + 2 ..]) catch return error.InvalidDate;
        return .{ .op = .range, .value = lower, .value_upper = upper + day_secs };
    }

    // Comparison: >YYYY-MM-DD or <YYYY-MM-DD
    if (input.len > 1 and input[0] == '>') {
        const ts = parseDateString(input[1..]) catch return error.InvalidDate;
        return .{ .op = .gt, .value = ts, .value_upper = 0 };
    }
    if (input.len > 1 and input[0] == '<') {
        const ts = parseDateString(input[1..]) catch return error.InvalidDate;
        return .{ .op = .lt, .value = ts, .value_upper = 0 };
    }

    // Exact date: YYYY-MM-DD (match that whole day)
    const ts = parseDateString(input) catch return error.InvalidDate;
    return .{ .op = .range, .value = ts, .value_upper = ts + day_secs };
}

pub const DateResult = struct {
    op: CompareOp,
    value: i64,
    value_upper: i64,
};

/// Parse "YYYY-MM-DD" into a unix timestamp (midnight UTC).
fn parseDateString(input: []const u8) !i64 {
    if (input.len != 10) return error.InvalidDate;
    if (input[4] != '-' or input[7] != '-') return error.InvalidDate;

    const year = std.fmt.parseInt(i32, input[0..4], 10) catch return error.InvalidDate;
    const month = std.fmt.parseInt(i32, input[5..7], 10) catch return error.InvalidDate;
    const day = std.fmt.parseInt(i32, input[8..10], 10) catch return error.InvalidDate;

    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidDate;

    // Days from epoch using the algorithm from http://howardhinnant.github.io/date_algorithms.html
    const m = month;
    const y = if (m <= 2) year - 1 else year;
    const era: i32 = @divFloor(y, 400);
    const yoe: i32 = y - era * 400;
    const doy: i32 = @divTrunc((153 * (if (m > 2) m - 3 else m + 9) + 2), 5) + day - 1;
    const doe: i32 = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    const epoch_days: i64 = @as(i64, era) * 146097 + @as(i64, doe) - 719468;

    return epoch_days * 86400;
}

/// Format a criterion back to its text representation for display.
pub fn formatCriterion(criterion: FilterCriterion, buf: []u8) []const u8 {
    return switch (criterion) {
        .kind => |f| {
            const prefix: []const u8 = if (f.negated) "!kind:" else "kind:";
            const val: []const u8 = switch (f.value) {
                .file => "file",
                .directory => "folder",
                .symlink => "symlink",
            };
            return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, val }) catch "";
        },
        .extension => |f| {
            const prefix: []const u8 = if (f.negated) "!ext:" else "ext:";
            return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, f.value[0..f.len] }) catch "";
        },
        .size => |f| formatSizeCriterion(f, buf),
        .date => |f| formatDateCriterion(f, buf),
        .category => |f| {
            const prefix: []const u8 = if (f.negated) "!cat:" else "cat:";
            return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, categoryName(f.value) }) catch "";
        },
        .path => |f| {
            const prefix: []const u8 = if (f.negated) "!path:" else "path:";
            return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, f.value[0..f.len] }) catch "";
        },
    };
}

fn categoryName(cat: types.FileCategory) []const u8 {
    return switch (cat) {
        .uncategorized => "other",
        .images => "images",
        .text => "text",
        .documents => "documents",
        .spreadsheets => "spreadsheets",
        .audio => "audio",
        .video => "video",
        .code => "code",
        .archives => "archives",
    };
}

fn formatSizeCriterion(f: anytype, buf: []u8) []const u8 {
    const op_str: []const u8 = switch (f.op) {
        .gt => ">",
        .lt => "<",
        .gte => ">=",
        .lte => "<=",
        .range => "",
        .eq => "",
    };
    if (f.op == .range) {
        var lower_buf: [32]u8 = undefined;
        var upper_buf: [32]u8 = undefined;
        const lower_str = formatBytesValue(f.value, &lower_buf);
        const upper_str = formatBytesValue(f.value_upper, &upper_buf);
        return std.fmt.bufPrint(buf, "size:{s}..{s}", .{ lower_str, upper_str }) catch "";
    }
    var val_buf: [32]u8 = undefined;
    const val_str = formatBytesValue(f.value, &val_buf);
    return std.fmt.bufPrint(buf, "size:{s}{s}", .{ op_str, val_str }) catch "";
}

fn formatBytesValue(bytes: u64, buf: []u8) []const u8 {
    if (bytes == 0) return std.fmt.bufPrint(buf, "0", .{}) catch "0";
    if (bytes >= 1024 * 1024 * 1024 and bytes % (1024 * 1024 * 1024) == 0) {
        return std.fmt.bufPrint(buf, "{d}gb", .{bytes / (1024 * 1024 * 1024)}) catch "";
    }
    if (bytes >= 1024 * 1024 and bytes % (1024 * 1024) == 0) {
        return std.fmt.bufPrint(buf, "{d}mb", .{bytes / (1024 * 1024)}) catch "";
    }
    if (bytes >= 1024 and bytes % 1024 == 0) {
        return std.fmt.bufPrint(buf, "{d}kb", .{bytes / 1024}) catch "";
    }
    // Non-round values: pick best unit
    if (bytes >= 1024 * 1024) {
        const mb_val = @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
        return std.fmt.bufPrint(buf, "{d:.1}mb", .{mb_val}) catch "";
    }
    if (bytes >= 1024) {
        const kb_val = @as(f64, @floatFromInt(bytes)) / 1024.0;
        return std.fmt.bufPrint(buf, "{d:.1}kb", .{kb_val}) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}b", .{bytes}) catch "";
}

fn formatDateCriterion(f: anytype, buf: []u8) []const u8 {
    const day_secs: i64 = 86400;
    const now = runtime.unixTimestamp();

    // Try to detect relative keywords
    if (f.op == .gte) {
        const diff = now - f.value;
        if (diff >= 0 and diff <= day_secs + 60) return "date:today";
        if (diff >= 6 * day_secs and diff <= 8 * day_secs) return "date:week";
        if (diff >= 29 * day_secs and diff <= 31 * day_secs) return "date:month";
        if (diff >= 364 * day_secs and diff <= 366 * day_secs) return "date:year";
    }

    // Fall back to absolute date formatting
    var date_buf1: [16]u8 = undefined;
    switch (f.op) {
        .gt => {
            const date_str = formatEpochDate(f.value, &date_buf1);
            return std.fmt.bufPrint(buf, "date:>{s}", .{date_str}) catch "";
        },
        .lt => {
            const date_str = formatEpochDate(f.value, &date_buf1);
            return std.fmt.bufPrint(buf, "date:<{s}", .{date_str}) catch "";
        },
        .range => {
            var date_buf2: [16]u8 = undefined;
            const lower_str = formatEpochDate(f.value, &date_buf1);
            const upper_str = formatEpochDate(f.value_upper - day_secs, &date_buf2);
            return std.fmt.bufPrint(buf, "date:{s}..{s}", .{ lower_str, upper_str }) catch "";
        },
        else => {
            const date_str = formatEpochDate(f.value, &date_buf1);
            return std.fmt.bufPrint(buf, "date:{s}", .{date_str}) catch "";
        },
    }
}

/// Format epoch seconds as "YYYY-MM-DD".
fn formatEpochDate(timestamp: i64, buf: []u8) []const u8 {
    if (timestamp <= 0) return "1970-01-01";
    const days = @divFloor(timestamp, @as(i64, 86400));
    // Inverse of the civil_from_days algorithm
    const z = days + 719468;
    const era_val = @divFloor(if (z >= 0) z else z - 146096, @as(i64, 146097));
    const doe = z - era_val * 146097;
    const yoe_calc = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y = yoe_calc + era_val * 400;
    const doy = doe - (365 * yoe_calc + @divFloor(yoe_calc, 4) - @divFloor(yoe_calc, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m_val = if (mp < 10) mp + 3 else mp - 9;
    const y_final = if (m_val <= 2) y + 1 else y;
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u16, @intCast(y_final)),
        @as(u8, @intCast(m_val)),
        @as(u8, @intCast(d)),
    }) catch "????-??-??";
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseSize basic units" {
    try std.testing.expectEqual(@as(u64, 100), try parseSize("100"));
    try std.testing.expectEqual(@as(u64, 100), try parseSize("100b"));
    try std.testing.expectEqual(@as(u64, 1024), try parseSize("1kb"));
    try std.testing.expectEqual(@as(u64, 1024), try parseSize("1k"));
    try std.testing.expectEqual(@as(u64, 1048576), try parseSize("1mb"));
    try std.testing.expectEqual(@as(u64, 1048576), try parseSize("1m"));
    try std.testing.expectEqual(@as(u64, 1073741824), try parseSize("1gb"));
    try std.testing.expectEqual(@as(u64, 500 * 1024), try parseSize("500kb"));
}

test "parseSize float" {
    try std.testing.expectEqual(@as(u64, 1572864), try parseSize("1.5mb"));
}

test "parseSize invalid" {
    try std.testing.expectError(error.InvalidSize, parseSize(""));
    try std.testing.expectError(error.InvalidSize, parseSize("abc"));
    try std.testing.expectError(error.InvalidSize, parseSize("1xx"));
}

test "filter kind matches" {
    const target = MatchTarget{ .kind = .directory, .name = "docs" };
    const f = FilterCriterion{ .kind = .{ .value = .directory } };
    try std.testing.expect(f.matches(target));

    const f2 = FilterCriterion{ .kind = .{ .value = .file } };
    try std.testing.expect(!f2.matches(target));

    const f3 = FilterCriterion{ .kind = .{ .negated = true, .value = .directory } };
    try std.testing.expect(!f3.matches(target));
}

test "filter extension matches" {
    const target = MatchTarget{ .name = "report.pdf" };
    var f = FilterCriterion{ .extension = .{} };
    @memcpy(f.extension.value[0..3], "pdf");
    f.extension.len = 3;
    try std.testing.expect(f.matches(target));

    const target2 = MatchTarget{ .name = "report.txt" };
    try std.testing.expect(!f.matches(target2));
}

test "filter extension case insensitive" {
    const target = MatchTarget{ .name = "IMAGE.PNG" };
    var f = FilterCriterion{ .extension = .{} };
    @memcpy(f.extension.value[0..3], "png");
    f.extension.len = 3;
    try std.testing.expect(f.matches(target));
}

test "filter size comparison" {
    const target = MatchTarget{ .size = 2 * 1024 * 1024 }; // 2MB
    const f_gt = FilterCriterion{ .size = .{ .op = .gt, .value = 1024 * 1024 } };
    try std.testing.expect(f_gt.matches(target));

    const f_lt = FilterCriterion{ .size = .{ .op = .lt, .value = 1024 * 1024 } };
    try std.testing.expect(!f_lt.matches(target));

    const f_range = FilterCriterion{ .size = .{ .op = .range, .value = 1024 * 1024, .value_upper = 3 * 1024 * 1024 } };
    try std.testing.expect(f_range.matches(target));
}

test "filter category matches" {
    const target = MatchTarget{ .category = .images };
    const f = FilterCriterion{ .category = .{ .value = .images } };
    try std.testing.expect(f.matches(target));

    const f2 = FilterCriterion{ .category = .{ .negated = true, .value = .images } };
    try std.testing.expect(!f2.matches(target));
}

test "filter path matches" {
    const target = MatchTarget{ .dir_path = "/Users/john/src/project" };
    var f = FilterCriterion{ .path = .{} };
    @memcpy(f.path.value[0..4], "src/");
    f.path.len = 4;
    try std.testing.expect(f.matches(target));
}

test "matchesAll AND logic" {
    const target = MatchTarget{
        .name = "report.pdf",
        .size = 2 * 1024 * 1024,
        .category = .documents,
    };
    var ext_filter = FilterCriterion{ .extension = .{} };
    @memcpy(ext_filter.extension.value[0..3], "pdf");
    ext_filter.extension.len = 3;

    const filters = [_]FilterCriterion{
        ext_filter,
        .{ .size = .{ .op = .gt, .value = 1024 * 1024 } },
        .{ .category = .{ .value = .documents } },
    };
    try std.testing.expect(matchesAll(&filters, target));

    // Fails if one filter doesn't match
    const filters2 = [_]FilterCriterion{
        ext_filter,
        .{ .size = .{ .op = .gt, .value = 10 * 1024 * 1024 } }, // > 10MB — doesn't match
    };
    try std.testing.expect(!matchesAll(&filters2, target));
}

test "parseDate relative" {
    const result = try parseDate("today");
    try std.testing.expectEqual(CompareOp.gte, result.op);
    try std.testing.expect(result.value > 0);
}

test "parseDate comparison" {
    const result = try parseDate(">2024-01-01");
    try std.testing.expectEqual(CompareOp.gt, result.op);
    try std.testing.expect(result.value > 0);
}

test "parseDate range" {
    const result = try parseDate("2024-01-01..2024-12-31");
    try std.testing.expectEqual(CompareOp.range, result.op);
    try std.testing.expect(result.value < result.value_upper);
}

test "parseDate invalid" {
    try std.testing.expectError(error.InvalidDate, parseDate("notadate"));
    try std.testing.expectError(error.InvalidDate, parseDate(">bad"));
}

test "formatCriterion kind" {
    var buf: [64]u8 = undefined;
    const f = FilterCriterion{ .kind = .{ .value = .directory } };
    const result = formatCriterion(f, &buf);
    try std.testing.expectEqualStrings("kind:folder", result);
}

test "formatCriterion negated kind" {
    var buf: [64]u8 = undefined;
    const f = FilterCriterion{ .kind = .{ .negated = true, .value = .symlink } };
    const result = formatCriterion(f, &buf);
    try std.testing.expectEqualStrings("!kind:symlink", result);
}

test "formatCriterion extension" {
    var buf: [64]u8 = undefined;
    var f = FilterCriterion{ .extension = .{} };
    @memcpy(f.extension.value[0..3], "pdf");
    f.extension.len = 3;
    const result = formatCriterion(f, &buf);
    try std.testing.expectEqualStrings("ext:pdf", result);
}

test "formatCriterion category" {
    var buf: [64]u8 = undefined;
    const f = FilterCriterion{ .category = .{ .value = .code } };
    const result = formatCriterion(f, &buf);
    try std.testing.expectEqualStrings("cat:code", result);
}

test "formatCriterion size gt round-trip" {
    var buf: [128]u8 = undefined;
    const f = FilterCriterion{ .size = .{ .op = .gt, .value = 1024 * 1024 } }; // >1mb
    const result = formatCriterion(f, &buf);
    try std.testing.expectEqualStrings("size:>1mb", result);
}

test "formatCriterion size range round-trip" {
    var buf: [128]u8 = undefined;
    const f = FilterCriterion{ .size = .{ .op = .range, .value = 1024 * 1024, .value_upper = 10 * 1024 * 1024 } };
    const result = formatCriterion(f, &buf);
    try std.testing.expectEqualStrings("size:1mb..10mb", result);
}

test "formatCriterion size 500kb" {
    var buf: [128]u8 = undefined;
    const f = FilterCriterion{ .size = .{ .op = .gt, .value = 500 * 1024 } };
    const result = formatCriterion(f, &buf);
    try std.testing.expectEqualStrings("size:>500kb", result);
}

test "formatCriterion date comparison" {
    var buf: [128]u8 = undefined;
    // Jan 1, 2024 midnight UTC = 1704067200
    const f = FilterCriterion{ .date = .{ .op = .gt, .value = 1704067200 } };
    const result = formatCriterion(f, &buf);
    try std.testing.expectEqualStrings("date:>2024-01-01", result);
}

test "formatEpochDate known date" {
    var buf: [16]u8 = undefined;
    // 2024-01-01 = 19723 days * 86400 = 1704067200
    const result = formatEpochDate(1704067200, &buf);
    try std.testing.expectEqualStrings("2024-01-01", result);
}

test "formatEpochDate epoch" {
    var buf: [16]u8 = undefined;
    const result = formatEpochDate(0, &buf);
    try std.testing.expectEqualStrings("1970-01-01", result);
}
