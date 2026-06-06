const std = @import("std");
const runtime = @import("runtime.zig");

pub const current_version: u32 = 1;

pub const FolderColor = struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8 = 255,
};

pub const FolderColorManager = struct {
    allocator: std.mem.Allocator,
    file_path: ?[]const u8,
    colors: std.StringHashMap(FolderColor),

    pub fn init(allocator: std.mem.Allocator, file_path: ?[]const u8) FolderColorManager {
        return .{
            .allocator = allocator,
            .file_path = file_path,
            .colors = std.StringHashMap(FolderColor).init(allocator),
        };
    }

    pub fn deinit(self: *FolderColorManager) void {
        self.clearAll();
        self.colors.deinit();
    }

    pub fn load(self: *FolderColorManager) !void {
        self.clearAll();

        const fp = self.file_path orelse return;
        self.loadFromFile(fp) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    }

    pub fn loadFromString(self: *FolderColorManager, data: []const u8) !void {
        self.clearAll();
        try self.parseJson(data);
    }

    pub fn save(self: *const FolderColorManager) !void {
        const fp = self.file_path orelse return error.NoFilePath;

        if (std.fs.path.dirname(fp)) |parent| try runtime.ensureDir(parent);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        var jw: std.json.Stringify = .{
            .writer = &out.writer,
            .options = .{ .whitespace = .indent_2 },
        };

        try jw.beginObject();
        try jw.objectField("version");
        try jw.write(current_version);
        try jw.objectField("folders");
        try jw.beginObject();

        var it = self.colors.iterator();
        while (it.next()) |entry| {
            try jw.objectField(entry.key_ptr.*);
            try jw.write(entry.value_ptr.*);
        }

        try jw.endObject();
        try jw.endObject();
        try out.writer.writeByte('\n');

        try runtime.writeFileAbsolute(fp, out.written());
    }

    pub fn getColor(self: *const FolderColorManager, path: []const u8) ?FolderColor {
        return self.colors.get(path);
    }

    pub fn setColor(self: *FolderColorManager, path: []const u8, color: FolderColor) !void {
        if (self.colors.getPtr(path)) |existing| {
            existing.* = color;
            return;
        }

        try self.colors.put(try self.allocator.dupe(u8, path), color);
    }

    pub fn clearColor(self: *FolderColorManager, path: []const u8) bool {
        const removed = self.colors.fetchRemove(path) orelse return false;
        self.allocator.free(removed.key);
        return true;
    }

    pub fn count(self: *const FolderColorManager) usize {
        return self.colors.count();
    }

    fn clearAll(self: *FolderColorManager) void {
        var it = self.colors.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.colors.clearRetainingCapacity();
    }

    fn loadFromFile(self: *FolderColorManager, path: []const u8) !void {
        const data = runtime.readFileAlloc(self.allocator, path, .limited(1024 * 1024)) catch return error.FileNotFound;
        defer self.allocator.free(data);

        try self.parseJson(data);
    }

    fn parseJson(self: *FolderColorManager, data: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidJson;

        if (root.object.get("version")) |version_value| {
            const version = parseVersion(version_value) orelse return error.InvalidJson;
            if (version > current_version) return error.UnsupportedVersion;
        }

        const folders_value = root.object.get("folders") orelse return;
        if (folders_value != .object) return error.InvalidJson;

        errdefer self.clearAll();

        var it = folders_value.object.iterator();
        while (it.next()) |entry| {
            const color = parseColor(entry.value_ptr.*) orelse continue;
            try self.setColor(entry.key_ptr.*, color);
        }
    }
};

fn parseVersion(value: std.json.Value) ?u32 {
    return switch (value) {
        .integer => |integer| if (integer >= 0 and integer <= std.math.maxInt(u32))
            @intCast(integer)
        else
            null,
        else => null,
    };
}

fn parseColor(value: std.json.Value) ?FolderColor {
    if (value != .object) return null;

    const red = parseColorComponent(value.object.get("red") orelse return null) orelse return null;
    const green = parseColorComponent(value.object.get("green") orelse return null) orelse return null;
    const blue = parseColorComponent(value.object.get("blue") orelse return null) orelse return null;
    const alpha = if (value.object.get("alpha")) |alpha_value|
        parseColorComponent(alpha_value) orelse return null
    else
        255;

    return .{
        .red = red,
        .green = green,
        .blue = blue,
        .alpha = alpha,
    };
}

fn parseColorComponent(value: std.json.Value) ?u8 {
    return switch (value) {
        .integer => |integer| if (integer >= 0 and integer <= std.math.maxInt(u8))
            @intCast(integer)
        else
            null,
        else => null,
    };
}

test "set, update, and clear folder colors" {
    var manager = FolderColorManager.init(std.testing.allocator, null);
    defer manager.deinit();

    try manager.setColor("/tmp/example", .{ .red = 100, .green = 120, .blue = 140 });
    try std.testing.expectEqual(@as(usize, 1), manager.count());
    try std.testing.expectEqual(FolderColor{ .red = 100, .green = 120, .blue = 140, .alpha = 255 }, manager.getColor("/tmp/example").?);

    try manager.setColor("/tmp/example", .{ .red = 1, .green = 2, .blue = 3, .alpha = 4 });
    try std.testing.expectEqual(@as(usize, 1), manager.count());
    try std.testing.expectEqual(FolderColor{ .red = 1, .green = 2, .blue = 3, .alpha = 4 }, manager.getColor("/tmp/example").?);

    try std.testing.expect(manager.clearColor("/tmp/example"));
    try std.testing.expect(manager.getColor("/tmp/example") == null);
    try std.testing.expectEqual(@as(usize, 0), manager.count());
}

test "save and load folder colors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(runtime.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ root, "state", "folder_colors.json" });
    defer std.testing.allocator.free(file_path);

    {
        var manager = FolderColorManager.init(std.testing.allocator, file_path);
        defer manager.deinit();

        try manager.setColor("/Users/helge/code", .{ .red = 24, .green = 120, .blue = 220 });
        try manager.setColor("/Users/helge/tmp", .{ .red = 200, .green = 100, .blue = 10, .alpha = 180 });
        try manager.save();
    }

    {
        var manager = FolderColorManager.init(std.testing.allocator, file_path);
        defer manager.deinit();

        try manager.load();
        try std.testing.expectEqual(@as(usize, 2), manager.count());
        try std.testing.expectEqual(FolderColor{ .red = 24, .green = 120, .blue = 220, .alpha = 255 }, manager.getColor("/Users/helge/code").?);
        try std.testing.expectEqual(FolderColor{ .red = 200, .green = 100, .blue = 10, .alpha = 180 }, manager.getColor("/Users/helge/tmp").?);
    }
}

test "invalid folder entries are skipped" {
    var manager = FolderColorManager.init(std.testing.allocator, null);
    defer manager.deinit();

    try manager.loadFromString(
        \\{
        \\  "version": 1,
        \\  "folders": {
        \\    "/valid": { "red": 1, "green": 2, "blue": 3 },
        \\    "/missing-blue": { "red": 1, "green": 2 },
        \\    "/wrong-type": "blue"
        \\  }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), manager.count());
    try std.testing.expectEqual(FolderColor{ .red = 1, .green = 2, .blue = 3, .alpha = 255 }, manager.getColor("/valid").?);
}
