const std = @import("std");
const runtime = @import("runtime.zig");
const types = @import("types.zig");
const config = @import("../config/config.zig");
const builtin = @import("builtin");

pub const current_version: u32 = 1;

pub const FolderColor = struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8 = 255,
};

pub const SavedFilter = struct {
    name: []const u8,
    query: []const u8,
};

pub const UserState = struct {
    allocator: std.mem.Allocator,
    pins_path: ?[]const u8,
    folder_colors_path: ?[]const u8,
    filters_path: ?[]const u8,
    config_path: ?[]const u8,

    // Data
    pins: std.ArrayList(types.Pin),
    folder_colors: std.StringHashMap(FolderColor),
    saved_filters: std.ArrayList(SavedFilter),
    terminal: ?[]const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        pins_path: ?[]const u8,
        folder_colors_path: ?[]const u8,
        filters_path: ?[]const u8,
        config_path: ?[]const u8,
    ) UserState {
        return .{
            .allocator = allocator,
            .pins_path = pins_path,
            .folder_colors_path = folder_colors_path,
            .filters_path = filters_path,
            .config_path = config_path,
            .pins = .empty,
            .folder_colors = std.StringHashMap(FolderColor).init(allocator),
            .saved_filters = .empty,
            .terminal = null,
        };
    }

    pub fn deinit(self: *UserState) void {
        // Free pins
        for (self.pins.items) |pin| {
            self.allocator.free(pin.name);
            self.allocator.free(pin.path);
        }
        self.pins.deinit(self.allocator);

        // Free folder colors
        self.clearAllFolderColors();
        self.folder_colors.deinit();

        // Free saved filters
        for (self.saved_filters.items) |sf| {
            self.allocator.free(sf.name);
            self.allocator.free(sf.query);
        }
        self.saved_filters.deinit(self.allocator);

        // Free terminal
        if (self.terminal) |t| self.allocator.free(t);
    }

    // -------------------------------------------------------------------------
    // Load / Save All
    // -------------------------------------------------------------------------

    pub fn loadAll(self: *UserState) void {
        self.loadPins() catch {};
        self.loadFolderColors() catch {};
        self.loadFilters() catch {};
        self.loadConfig();
    }

    pub fn saveAll(self: *UserState) void {
        self.savePins() catch {};
        self.saveFolderColors() catch {};
        self.saveFilters() catch {};
    }

    // -------------------------------------------------------------------------
    // Pins
    // -------------------------------------------------------------------------

    pub fn loadPins(self: *UserState) !void {
        for (self.pins.items) |pin| {
            self.allocator.free(pin.name);
            self.allocator.free(pin.path);
        }
        self.pins.clearRetainingCapacity();

        if (self.pins_path) |fp| {
            if (self.loadPinsFromFile(fp)) {
                return;
            } else |_| {}
        }
        try self.loadDefaultPins();
    }

    fn loadPinsFromFile(self: *UserState, path: []const u8) !void {
        const data = runtime.readFileAlloc(self.allocator, path, .limited(1024 * 1024)) catch return error.FileNotFound;
        defer self.allocator.free(data);
        try self.parsePinsJson(data);
    }

    pub fn loadPinsFromString(self: *UserState, data: []const u8) !void {
        for (self.pins.items) |pin| {
            self.allocator.free(pin.name);
            self.allocator.free(pin.path);
        }
        self.pins.clearRetainingCapacity();
        try self.parsePinsJson(data);
    }

    fn parsePinsJson(self: *UserState, data: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .array) return error.InvalidJson;

        for (root.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const name_val = obj.get("name") orelse continue;
            const path_val = obj.get("path") orelse continue;
            if (name_val != .string or path_val != .string) continue;

            const is_default = if (obj.get("is_default")) |d| d == .bool and d.bool else false;

            try self.pins.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name_val.string),
                .path = try self.allocator.dupe(u8, path_val.string),
                .is_default = is_default,
            });
        }
    }

    pub fn loadDefaultPins(self: *UserState) !void {
        const home = runtime.getEnvVarOwned(self.allocator, "HOME") catch return error.HomeNotFound;
        defer self.allocator.free(home);

        const defaults = [_]struct { name: []const u8, suffix: []const u8 }{
            .{ .name = "Home", .suffix = "" },
            .{ .name = "Desktop", .suffix = "/Desktop" },
            .{ .name = "Documents", .suffix = "/Documents" },
            .{ .name = "Downloads", .suffix = "/Downloads" },
        };

        for (defaults) |d| {
            const path = if (d.suffix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ home, d.suffix })
            else
                try self.allocator.dupe(u8, home);

            try self.pins.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, d.name),
                .path = path,
                .is_default = true,
            });
        }
    }

    pub fn savePins(self: *UserState) !void {
        const fp = self.pins_path orelse return error.NoFilePath;
        if (std.fs.path.dirname(fp)) |parent| try runtime.ensureDir(parent);
        const json = try self.pinsToJson();
        defer self.allocator.free(json);
        try runtime.writeFileAbsolute(fp, json);
    }

    fn pinsToJson(self: UserState) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        const writer = &out.writer;

        try writer.writeAll("[\n");
        for (self.pins.items, 0..) |pin, i| {
            try writer.print("  {{\"name\": \"{s}\", \"path\": \"{s}\", \"is_default\": {}}}", .{
                pin.name,
                pin.path,
                pin.is_default,
            });
            if (i < self.pins.items.len - 1) try writer.writeAll(",");
            try writer.writeAll("\n");
        }
        try writer.writeAll("]\n");
        return out.toOwnedSlice();
    }

    pub fn addPin(self: *UserState, name: []const u8, path: []const u8) !void {
        for (self.pins.items) |pin| {
            if (std.mem.eql(u8, pin.path, path)) return;
        }
        try self.pins.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .path = try self.allocator.dupe(u8, path),
            .is_default = false,
        });
    }

    pub fn removePin(self: *UserState, path: []const u8) bool {
        for (self.pins.items, 0..) |pin, i| {
            if (std.mem.eql(u8, pin.path, path)) {
                self.allocator.free(pin.name);
                self.allocator.free(pin.path);
                _ = self.pins.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn getPins(self: UserState) []const types.Pin {
        return self.pins.items;
    }

    // -------------------------------------------------------------------------
    // Folder Colors
    // -------------------------------------------------------------------------

    pub fn loadFolderColors(self: *UserState) !void {
        self.clearAllFolderColors();
        const fp = self.folder_colors_path orelse return;
        self.loadFolderColorsFromFile(fp) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
    }

    pub fn loadFolderColorsFromString(self: *UserState, data: []const u8) !void {
        self.clearAllFolderColors();
        try self.parseFolderColorsJson(data);
    }

    fn loadFolderColorsFromFile(self: *UserState, path: []const u8) !void {
        const data = runtime.readFileAlloc(self.allocator, path, .limited(1024 * 1024)) catch return error.FileNotFound;
        defer self.allocator.free(data);
        try self.parseFolderColorsJson(data);
    }

    fn parseFolderColorsJson(self: *UserState, data: []const u8) !void {
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

        errdefer self.clearAllFolderColors();

        var it = folders_value.object.iterator();
        while (it.next()) |entry| {
            const color = parseColor(entry.value_ptr.*) orelse continue;
            try self.setFolderColor(entry.key_ptr.*, color);
        }
    }

    pub fn saveFolderColors(self: *const UserState) !void {
        const fp_fp = self.folder_colors_path orelse return error.NoFilePath;
        if (std.fs.path.dirname(fp_fp)) |parent| try runtime.ensureDir(parent);

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

        var it = self.folder_colors.iterator();
        while (it.next()) |entry| {
            try jw.objectField(entry.key_ptr.*);
            try jw.write(entry.value_ptr.*);
        }

        try jw.endObject();
        try jw.endObject();
        try out.writer.writeByte('\n');

        try runtime.writeFileAbsolute(fp_fp, out.written());
    }

    pub fn getFolderColor(self: *const UserState, path: []const u8) ?FolderColor {
        return self.folder_colors.get(path);
    }

    pub fn setFolderColor(self: *UserState, path: []const u8, color: FolderColor) !void {
        if (self.folder_colors.getPtr(path)) |existing| {
            existing.* = color;
            return;
        }
        try self.folder_colors.put(try self.allocator.dupe(u8, path), color);
    }

    pub fn clearFolderColor(self: *UserState, path: []const u8) bool {
        const removed = self.folder_colors.fetchRemove(path) orelse return false;
        self.allocator.free(removed.key);
        return true;
    }

    pub fn folderColorCount(self: *const UserState) usize {
        return self.folder_colors.count();
    }

    fn clearAllFolderColors(self: *UserState) void {
        var it = self.folder_colors.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.folder_colors.clearRetainingCapacity();
    }

    // -------------------------------------------------------------------------
    // Saved Filters
    // -------------------------------------------------------------------------

    pub fn loadFilters(self: *UserState) !void {
        const file_path = self.filters_path orelse return error.NoPath;
        const data = runtime.readFileAlloc(self.allocator, file_path, .limited(1024 * 1024)) catch return error.FileNotFound;
        defer self.allocator.free(data);

        const parsed = std.json.parseFromSlice(JsonRoot, self.allocator, data, .{ .allocate = .alloc_always }) catch return error.ParseError;
        defer parsed.deinit();

        for (parsed.value.saved_filters) |sf| {
            try self.saved_filters.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, sf.name),
                .query = try self.allocator.dupe(u8, sf.query),
            });
        }
    }

    pub fn saveFilters(self: *UserState) !void {
        const file_path = self.filters_path orelse return error.NoPath;
        if (std.fs.path.dirname(file_path)) |dir| runtime.ensureDir(dir) catch return error.DirError;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        buf.appendSlice(self.allocator, "{\"saved_filters\":[") catch return error.WriteError;
        for (self.saved_filters.items, 0..) |item, i| {
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

    pub fn getSavedFilters(self: *const UserState) []const SavedFilter {
        return self.saved_filters.items;
    }

    pub fn addSavedFilter(self: *UserState, name: []const u8, query: []const u8) !void {
        try self.saved_filters.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .query = try self.allocator.dupe(u8, query),
        });
    }

    pub fn removeSavedFilter(self: *UserState, name: []const u8) bool {
        for (self.saved_filters.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.name, name)) {
                self.allocator.free(item.name);
                self.allocator.free(item.query);
                _ = self.saved_filters.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    // -------------------------------------------------------------------------
    // Config (terminal preference)
    // -------------------------------------------------------------------------

    pub fn loadConfig(self: *UserState) void {
        const fp = self.config_path orelse return;
        const data = runtime.readFileAlloc(self.allocator, fp, .limited(1024 * 1024)) catch return;
        defer self.allocator.free(data);
        self.parseConfigJson(data) catch {};
    }

    pub fn loadConfigFromString(self: *UserState, data: []const u8) !void {
        try self.parseConfigJson(data);
    }

    fn parseConfigJson(self: *UserState, data: []const u8) !void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return error.InvalidJson;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidJson;

        if (root.object.get("terminal")) |value| {
            if (value == .string and value.string.len > 0) {
                if (self.terminal) |t| self.allocator.free(t);
                self.terminal = try self.allocator.dupe(u8, value.string);
            }
        }
    }

    pub fn getTerminal(self: UserState) ?[]const u8 {
        return self.terminal;
    }

    pub fn setTerminal(self: *UserState, terminal: []const u8) !void {
        if (self.terminal) |t| self.allocator.free(t);
        self.terminal = try self.allocator.dupe(u8, terminal);
    }
};

// -------------------------------------------------------------------------
// JSON helpers (moved from filter_store.zig)
// -------------------------------------------------------------------------

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

// -------------------------------------------------------------------------
// Color parsing helpers (moved from folder_colors.zig)
// -------------------------------------------------------------------------

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

// -------------------------------------------------------------------------
// Tests (migrated from all three modules)
// -------------------------------------------------------------------------

test "UserState: set, update, and clear folder colors" {
    var state = UserState.init(std.testing.allocator, null, null, null, null);
    defer state.deinit();

    try state.setFolderColor("/tmp/example", .{ .red = 100, .green = 120, .blue = 140 });
    try std.testing.expectEqual(@as(usize, 1), state.folderColorCount());
    try std.testing.expectEqual(FolderColor{ .red = 100, .green = 120, .blue = 140, .alpha = 255 }, state.getFolderColor("/tmp/example").?);

    try state.setFolderColor("/tmp/example", .{ .red = 1, .green = 2, .blue = 3, .alpha = 4 });
    try std.testing.expectEqual(@as(usize, 1), state.folderColorCount());
    try std.testing.expectEqual(FolderColor{ .red = 1, .green = 2, .blue = 3, .alpha = 4 }, state.getFolderColor("/tmp/example").?);

    try std.testing.expect(state.clearFolderColor("/tmp/example"));
    try std.testing.expect(state.getFolderColor("/tmp/example") == null);
    try std.testing.expectEqual(@as(usize, 0), state.folderColorCount());
}

test "UserState: save and load folder colors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(runtime.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ root, "state", "folder_colors.json" });
    defer std.testing.allocator.free(file_path);

    {
        var state = UserState.init(std.testing.allocator, null, file_path, null, null);
        defer state.deinit();

        try state.setFolderColor("/Users/helge/code", .{ .red = 24, .green = 120, .blue = 220 });
        try state.setFolderColor("/Users/helge/tmp", .{ .red = 200, .green = 100, .blue = 10, .alpha = 180 });
        try state.saveFolderColors();
    }

    {
        var state = UserState.init(std.testing.allocator, null, file_path, null, null);
        defer state.deinit();

        try state.loadFolderColors();
        try std.testing.expectEqual(@as(usize, 2), state.folderColorCount());
        try std.testing.expectEqual(FolderColor{ .red = 24, .green = 120, .blue = 220, .alpha = 255 }, state.getFolderColor("/Users/helge/code").?);
        try std.testing.expectEqual(FolderColor{ .red = 200, .green = 100, .blue = 10, .alpha = 180 }, state.getFolderColor("/Users/helge/tmp").?);
    }
}

test "UserState: invalid folder entries are skipped" {
    var state = UserState.init(std.testing.allocator, null, null, null, null);
    defer state.deinit();

    try state.loadFolderColorsFromString(
        \\{
        \\  "version": 1,
        \\  "folders": {
        \\    "/valid": { "red": 1, "green": 2, "blue": 3 },
        \\    "/missing-blue": { "red": 1, "green": 2 },
        \\    "/wrong-type": "blue"
        \\  }
        \\}
    );

    try std.testing.expectEqual(@as(usize, 1), state.folderColorCount());
    try std.testing.expectEqual(FolderColor{ .red = 1, .green = 2, .blue = 3, .alpha = 255 }, state.getFolderColor("/valid").?);
}

test "UserState: pin add and remove" {
    var state = UserState.init(std.testing.allocator, null, null, null, null);
    defer state.deinit();

    try state.addPin("Projects", "/Users/helge/code");
    try state.addPin("Downloads", "/Users/helge/Downloads");
    try std.testing.expectEqual(@as(usize, 2), state.getPins().len);

    // Duplicate path should be ignored
    try state.addPin("Code", "/Users/helge/code");
    try std.testing.expectEqual(@as(usize, 2), state.getPins().len);

    try std.testing.expect(state.removePin("/Users/helge/code"));
    try std.testing.expectEqual(@as(usize, 1), state.getPins().len);
    try std.testing.expect(!state.removePin("/nonexistent"));
}

test "UserState: load default pins" {
    // Skipping: loadDefaultPins requires runtime.environ_map which is only
    // initialized in main(), not in test builds.
    if (builtin.is_test) return error.SkipZigTest;
    var state = UserState.init(std.testing.allocator, null, null, null, null);
    defer state.deinit();

    try state.loadDefaultPins();
    const pins = state.getPins();
    try std.testing.expect(pins.len >= 4);
    try std.testing.expect(pins[0].is_default);
    try std.testing.expectEqualStrings("Home", pins[0].name);
}

test "UserState: saved filters add and remove" {
    var state = UserState.init(std.testing.allocator, null, null, null, null);
    defer state.deinit();

    try state.addSavedFilter("Large PDFs", "ext:pdf size:>1mb");
    try state.addSavedFilter("Recent Code", "cat:code date:week");

    const filters = state.getSavedFilters();
    try std.testing.expectEqual(@as(usize, 2), filters.len);
    try std.testing.expectEqualStrings("Large PDFs", filters[0].name);
    try std.testing.expectEqualStrings("ext:pdf size:>1mb", filters[0].query);

    try std.testing.expect(state.removeSavedFilter("Large PDFs"));
    try std.testing.expectEqual(@as(usize, 1), state.getSavedFilters().len);
    try std.testing.expect(!state.removeSavedFilter("Nonexistent"));
}

test "UserState: terminal config" {
    var state = UserState.init(std.testing.allocator, null, null, null, null);
    defer state.deinit();

    try std.testing.expect(state.getTerminal() == null);

    try state.loadConfigFromString(
        \\{ "terminal": "iTerm" }
    );
    try std.testing.expect(state.getTerminal() != null);
    try std.testing.expectEqualStrings("iTerm", state.getTerminal().?);

    try state.setTerminal("Warp");
    try std.testing.expectEqualStrings("Warp", state.getTerminal().?);
}

test "UserState: missing terminal key leaves config null" {
    var state = UserState.init(std.testing.allocator, null, null, null, null);
    defer state.deinit();

    try state.loadConfigFromString("{}");
    try std.testing.expect(state.getTerminal() == null);
}

test "UserState: non-string terminal value is ignored" {
    var state = UserState.init(std.testing.allocator, null, null, null, null);
    defer state.deinit();

    try state.loadConfigFromString(
        \\{ "terminal": 5 }
    );
    try std.testing.expect(state.getTerminal() == null);
}
