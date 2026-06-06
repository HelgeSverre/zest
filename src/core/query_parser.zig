const std = @import("std");
const filters = @import("filters.zig");
const types = @import("types.zig");

pub const ParsedQuery = struct {
    text: []const u8,
    filters_list: []filters.FilterCriterion,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedQuery) void {
        self.allocator.free(self.text);
        self.allocator.free(self.filters_list);
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !ParsedQuery {
    var text_parts: std.ArrayList([]const u8) = .empty;
    defer text_parts.deinit(allocator);
    var filter_list: std.ArrayList(filters.FilterCriterion) = .empty;
    defer filter_list.deinit(allocator);

    var iter = std.mem.tokenizeScalar(u8, input, ' ');
    while (iter.next()) |token| {
        if (parseQualifier(token)) |criterion| {
            try filter_list.append(allocator, criterion);
        } else {
            try text_parts.append(allocator, token);
        }
    }

    // Join text parts with spaces
    const text = if (text_parts.items.len == 0)
        try allocator.dupe(u8, "")
    else
        try std.mem.join(allocator, " ", text_parts.items);

    return .{
        .text = text,
        .filters_list = try filter_list.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

fn parseQualifier(token: []const u8) ?filters.FilterCriterion {
    // Check for [!]key:value pattern
    var rest = token;
    var negated = false;
    if (rest.len > 0 and rest[0] == '!') {
        negated = true;
        rest = rest[1..];
    }

    const colon_pos = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    if (colon_pos == 0 or colon_pos >= rest.len - 1) return null;

    const key = rest[0..colon_pos];
    const value = rest[colon_pos + 1 ..];

    if (std.ascii.eqlIgnoreCase(key, "kind")) {
        return parseKind(negated, value);
    } else if (std.ascii.eqlIgnoreCase(key, "ext")) {
        return parseExtension(negated, value);
    } else if (std.ascii.eqlIgnoreCase(key, "size")) {
        return parseSizeFilter(value);
    } else if (std.ascii.eqlIgnoreCase(key, "date")) {
        return parseDateFilter(value);
    } else if (std.ascii.eqlIgnoreCase(key, "cat")) {
        return parseCategory(negated, value);
    } else if (std.ascii.eqlIgnoreCase(key, "path")) {
        return parsePath(negated, value);
    }

    return null;
}

fn parseKind(negated: bool, value: []const u8) ?filters.FilterCriterion {
    const kind: types.FileKind = if (std.ascii.eqlIgnoreCase(value, "file"))
        .file
    else if (std.ascii.eqlIgnoreCase(value, "folder") or std.ascii.eqlIgnoreCase(value, "dir") or std.ascii.eqlIgnoreCase(value, "directory"))
        .directory
    else if (std.ascii.eqlIgnoreCase(value, "symlink") or std.ascii.eqlIgnoreCase(value, "link"))
        .symlink
    else
        return null;

    return .{ .kind = .{ .negated = negated, .value = kind } };
}

fn parseExtension(negated: bool, value: []const u8) ?filters.FilterCriterion {
    if (value.len == 0 or value.len > 32) return null;
    var f = filters.FilterCriterion{ .extension = .{ .negated = negated } };
    // Store lowercase
    for (value, 0..) |ch, i| {
        f.extension.value[i] = std.ascii.toLower(ch);
    }
    f.extension.len = @intCast(value.len);
    return f;
}

fn parseSizeFilter(value: []const u8) ?filters.FilterCriterion {
    // Range: 1mb..10mb
    if (std.mem.indexOf(u8, value, "..")) |sep| {
        const lower = filters.parseSize(value[0..sep]) catch return null;
        const upper = filters.parseSize(value[sep + 2 ..]) catch return null;
        return .{ .size = .{ .op = .range, .value = lower, .value_upper = upper } };
    }

    // Comparison operators
    if (value.len > 1) {
        if (value[0] == '>' and value[1] == '=') {
            const bytes = filters.parseSize(value[2..]) catch return null;
            return .{ .size = .{ .op = .gte, .value = bytes } };
        }
        if (value[0] == '<' and value[1] == '=') {
            const bytes = filters.parseSize(value[2..]) catch return null;
            return .{ .size = .{ .op = .lte, .value = bytes } };
        }
        if (value[0] == '>') {
            const bytes = filters.parseSize(value[1..]) catch return null;
            return .{ .size = .{ .op = .gt, .value = bytes } };
        }
        if (value[0] == '<') {
            const bytes = filters.parseSize(value[1..]) catch return null;
            return .{ .size = .{ .op = .lt, .value = bytes } };
        }
    }

    // Exact
    const bytes = filters.parseSize(value) catch return null;
    return .{ .size = .{ .op = .eq, .value = bytes } };
}

fn parseDateFilter(value: []const u8) ?filters.FilterCriterion {
    const result = filters.parseDate(value) catch return null;
    return .{ .date = .{ .op = result.op, .value = result.value, .value_upper = result.value_upper } };
}

fn parseCategory(negated: bool, value: []const u8) ?filters.FilterCriterion {
    const cat: types.FileCategory = if (std.ascii.eqlIgnoreCase(value, "images") or std.ascii.eqlIgnoreCase(value, "image"))
        .images
    else if (std.ascii.eqlIgnoreCase(value, "text"))
        .text
    else if (std.ascii.eqlIgnoreCase(value, "documents") or std.ascii.eqlIgnoreCase(value, "docs") or std.ascii.eqlIgnoreCase(value, "doc"))
        .documents
    else if (std.ascii.eqlIgnoreCase(value, "spreadsheets") or std.ascii.eqlIgnoreCase(value, "sheets"))
        .spreadsheets
    else if (std.ascii.eqlIgnoreCase(value, "audio"))
        .audio
    else if (std.ascii.eqlIgnoreCase(value, "video"))
        .video
    else if (std.ascii.eqlIgnoreCase(value, "code"))
        .code
    else if (std.ascii.eqlIgnoreCase(value, "archives") or std.ascii.eqlIgnoreCase(value, "archive"))
        .archives
    else if (std.ascii.eqlIgnoreCase(value, "other") or std.ascii.eqlIgnoreCase(value, "uncategorized"))
        .uncategorized
    else
        return null;

    return .{ .category = .{ .negated = negated, .value = cat } };
}

fn parsePath(negated: bool, value: []const u8) ?filters.FilterCriterion {
    if (value.len == 0 or value.len > 255) return null;
    var f = filters.FilterCriterion{ .path = .{ .negated = negated } };
    @memcpy(f.path.value[0..value.len], value);
    f.path.len = @intCast(value.len);
    return f;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse plain text only" {
    var result = try parse(std.testing.allocator, "hello world");
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.filters_list.len);
}

test "parse kind:folder only" {
    var result = try parse(std.testing.allocator, "kind:folder");
    defer result.deinit();
    try std.testing.expectEqualStrings("", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.filters_list.len);
    try std.testing.expectEqual(types.FileKind.directory, result.filters_list[0].kind.value);
}

test "parse mixed text and filters" {
    var result = try parse(std.testing.allocator, "report ext:pdf size:>1mb");
    defer result.deinit();
    try std.testing.expectEqualStrings("report", result.text);
    try std.testing.expectEqual(@as(usize, 2), result.filters_list.len);
    // First filter: ext:pdf
    try std.testing.expectEqualStrings("pdf", result.filters_list[0].extension.value[0..result.filters_list[0].extension.len]);
    // Second filter: size:>1mb
    try std.testing.expectEqual(filters.CompareOp.gt, result.filters_list[1].size.op);
    try std.testing.expectEqual(@as(u64, 1048576), result.filters_list[1].size.value);
}

test "parse negated filter" {
    var result = try parse(std.testing.allocator, "!ext:lock !kind:symlink");
    defer result.deinit();
    try std.testing.expectEqualStrings("", result.text);
    try std.testing.expectEqual(@as(usize, 2), result.filters_list.len);
    try std.testing.expect(result.filters_list[0].extension.negated);
    try std.testing.expect(result.filters_list[1].kind.negated);
}

test "parse category filter" {
    var result = try parse(std.testing.allocator, "cat:images date:week");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.filters_list.len);
    try std.testing.expectEqual(types.FileCategory.images, result.filters_list[0].category.value);
}

test "parse size range" {
    var result = try parse(std.testing.allocator, "size:1mb..10mb");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.filters_list.len);
    try std.testing.expectEqual(filters.CompareOp.range, result.filters_list[0].size.op);
    try std.testing.expectEqual(@as(u64, 1048576), result.filters_list[0].size.value);
    try std.testing.expectEqual(@as(u64, 10485760), result.filters_list[0].size.value_upper);
}

test "parse path filter" {
    var result = try parse(std.testing.allocator, "path:src/");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.filters_list.len);
    try std.testing.expectEqualStrings("src/", result.filters_list[0].path.value[0..result.filters_list[0].path.len]);
}

test "parse empty input" {
    var result = try parse(std.testing.allocator, "");
    defer result.deinit();
    try std.testing.expectEqualStrings("", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.filters_list.len);
}

test "unknown qualifier treated as text" {
    var result = try parse(std.testing.allocator, "foo:bar hello");
    defer result.deinit();
    try std.testing.expectEqualStrings("foo:bar hello", result.text);
    try std.testing.expectEqual(@as(usize, 0), result.filters_list.len);
}

test "parse multiple text words with filter" {
    var result = try parse(std.testing.allocator, "my report ext:pdf");
    defer result.deinit();
    try std.testing.expectEqualStrings("my report", result.text);
    try std.testing.expectEqual(@as(usize, 1), result.filters_list.len);
}
