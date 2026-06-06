const std = @import("std");
const runtime = @import("runtime.zig");

pub const SavedFilter = struct {
    name: []const u8,
    query: []const u8,
};

pub const FilterStore = struct {
    allocator: std.mem.Allocator,
    saved: std.ArrayList(SavedFilter),
    path: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8) FilterStore {
        return .{
            .allocator = allocator,
            .saved = .empty,
            .path = path,
        };
    }

    pub fn deinit(self: *FilterStore) void {
        for (self.saved.items) |item| {
            self.allocator.free(item.name);
            self.allocator.free(item.query);
        }
        self.saved.deinit(self.allocator);
    }

    pub fn load(self: *FilterStore) !void {
        const file_path = self.path orelse return error.NoPath;
        const data = runtime.readFileAlloc(self.allocator, file_path, .limited(1024 * 1024)) catch return error.FileNotFound;
        defer self.allocator.free(data);

        const parsed = std.json.parseFromSlice(JsonRoot, self.allocator, data, .{ .allocate = .alloc_always }) catch return error.ParseError;
        defer parsed.deinit();

        for (parsed.value.saved_filters) |sf| {
            try self.saved.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, sf.name),
                .query = try self.allocator.dupe(u8, sf.query),
            });
        }
    }

    pub fn save(self: *FilterStore) !void {
        const file_path = self.path orelse return error.NoPath;

        // Ensure parent directory exists
        if (std.fs.path.dirname(file_path)) |dir| runtime.ensureDir(dir) catch return error.DirError;

        // Build JSON string in memory with proper escaping
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        buf.appendSlice(self.allocator, "{\"saved_filters\":[") catch return error.WriteError;
        for (self.saved.items, 0..) |item, i| {
            if (i > 0) buf.append(self.allocator, ',') catch return error.WriteError;
            buf.appendSlice(self.allocator, "{\"name\":\"") catch return error.WriteError;
            appendJsonEscaped(&buf, self.allocator, item.name) catch return error.WriteError;
            buf.appendSlice(self.allocator, "\",\"query\":\"") catch return error.WriteError;
            appendJsonEscaped(&buf, self.allocator, item.query) catch return error.WriteError;
            buf.appendSlice(self.allocator, "\"}") catch return error.WriteError;
        }
        buf.appendSlice(self.allocator, "]}") catch return error.WriteError;
        runtime.writeFileAbsolute(file_path, buf.items) catch return error.WriteError;
    }

    pub fn getSaved(self: *const FilterStore) []const SavedFilter {
        return self.saved.items;
    }

    pub fn addSaved(self: *FilterStore, name: []const u8, query: []const u8) !void {
        try self.saved.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .query = try self.allocator.dupe(u8, query),
        });
    }

    pub fn removeSaved(self: *FilterStore, name: []const u8) bool {
        for (self.saved.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.name, name)) {
                self.allocator.free(item.name);
                self.allocator.free(item.query);
                _ = self.saved.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, ch),
        }
    }
}

const JsonSavedFilter = struct {
    name: []const u8,
    query: []const u8,
};

const JsonRoot = struct {
    saved_filters: []const JsonSavedFilter = &.{},
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "FilterStore add and get" {
    var store = FilterStore.init(std.testing.allocator, null);
    defer store.deinit();

    try store.addSaved("Large PDFs", "ext:pdf size:>1mb");
    try store.addSaved("Recent Code", "cat:code date:week");

    const saved = store.getSaved();
    try std.testing.expectEqual(@as(usize, 2), saved.len);
    try std.testing.expectEqualStrings("Large PDFs", saved[0].name);
    try std.testing.expectEqualStrings("ext:pdf size:>1mb", saved[0].query);
}

test "FilterStore remove" {
    var store = FilterStore.init(std.testing.allocator, null);
    defer store.deinit();

    try store.addSaved("Test", "kind:folder");
    try std.testing.expectEqual(@as(usize, 1), store.getSaved().len);

    try std.testing.expect(store.removeSaved("Test"));
    try std.testing.expectEqual(@as(usize, 0), store.getSaved().len);
    try std.testing.expect(!store.removeSaved("Nonexistent"));
}
