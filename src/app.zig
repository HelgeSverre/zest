const std = @import("std");
const types = @import("core/types.zig");
const navigator_mod = @import("core/navigator.zig");
const pins_mod = @import("core/pins.zig");
const fs_provider = @import("core/fs_provider.zig");
const reader_mod = @import("index/reader.zig");
const search_mod = @import("index/search.zig");
const config = @import("config/config.zig");

pub const App = struct {
    navigator: navigator_mod.Navigator,
    pin_manager: pins_mod.PinManager,
    fs: fs_provider.FileSystemProvider,
    index_reader: ?reader_mod.IndexReader,
    index_data: ?[]const u8,
    allocator: std.mem.Allocator,
    pins_path: ?[]const u8,
    index_inode: ?u64 = null,
    last_index_check: i128 = 0,

    pub fn init(allocator: std.mem.Allocator, fs: fs_provider.FileSystemProvider, initial_path: []const u8) !App {
        const pins_path = config.pinsPath(allocator) catch null;

        var app = App{
            .navigator = try navigator_mod.Navigator.init(allocator, initial_path),
            .pin_manager = pins_mod.PinManager.init(allocator, pins_path),
            .fs = fs,
            .index_reader = null,
            .index_data = null,
            .allocator = allocator,
            .pins_path = pins_path,
        };

        app.pin_manager.load() catch {
            app.pin_manager.loadDefaults() catch {};
        };

        return app;
    }

    pub fn deinit(self: *App) void {
        self.navigator.deinit();
        self.pin_manager.deinit();
        if (self.index_reader) |*ir| ir.deinit();
        if (self.index_data) |d| self.allocator.free(d);
        if (self.pins_path) |pp| self.allocator.free(pp);
    }

    // Navigation
    pub fn openDirectory(self: *App, path: []const u8) !void {
        if (!self.fs.isDir(path)) return error.NotADirectory;
        try self.navigator.navigate(path);
    }

    pub fn goBack(self: *App) !bool {
        return self.navigator.goBack();
    }

    pub fn goForward(self: *App) !bool {
        return self.navigator.goForward();
    }

    pub fn goUp(self: *App) !bool {
        return self.navigator.goUp();
    }

    pub fn currentPath(self: App) []const u8 {
        return self.navigator.current;
    }

    // File listing
    pub fn getCurrentEntries(self: *App) !types.DirListing {
        return self.fs.listDir(self.allocator, self.navigator.current);
    }

    // Search
    pub fn search(self: *App, query: []const u8, category: ?types.FileCategory) ![]search_mod.SearchResult {
        if (self.index_reader) |*ir| {
            return search_mod.search(self.allocator, ir, .{
                .query = query,
                .category = category,
            });
        }
        return self.allocator.alloc(search_mod.SearchResult, 0);
    }

    // Pins
    pub fn addPin(self: *App, name: []const u8, path: []const u8) !void {
        try self.pin_manager.addPin(name, path);
        self.pin_manager.save() catch {};
    }

    pub fn removePin(self: *App, path: []const u8) void {
        _ = self.pin_manager.removePin(path);
        self.pin_manager.save() catch {};
    }

    pub fn getPins(self: App) []const types.Pin {
        return self.pin_manager.getPins();
    }

    // Open files/directories
    pub fn openFile(self: *App, path: []const u8) !void {
        _ = self;
        const argv: []const []const u8 = &.{ "open", path };
        var child = std.process.Child.init(argv, std.heap.page_allocator);
        try child.spawn();
    }

    pub fn openInTerminal(self: *App, path: []const u8) !void {
        _ = self;
        const argv: []const []const u8 = &.{ "open", "-a", "Terminal", path };
        var child = std.process.Child.init(argv, std.heap.page_allocator);
        try child.spawn();
    }

    // Index
    pub fn loadIndex(self: *App, data: []const u8) !void {
        if (self.index_reader) |*ir| ir.deinit();
        if (self.index_data) |d| self.allocator.free(d);
        self.index_reader = try reader_mod.IndexReader.init(self.allocator, data);
        self.index_data = data;
    }

    pub fn getIndexStatus(self: App) types.IndexStatus {
        if (self.index_reader) |_| return .ready;
        return .not_found;
    }

    /// Check if the index file has changed on disk and reload it if so.
    /// Only performs the stat check every 5 seconds to avoid excessive syscalls.
    pub fn checkForIndexUpdate(self: *App) void {
        const check_interval_ns: i128 = 5 * std.time.ns_per_s;
        const now = std.time.nanoTimestamp();
        if (now - self.last_index_check < check_interval_ns) return;
        self.last_index_check = now;

        const idx_path = config.indexPath(self.allocator) catch return;
        defer self.allocator.free(idx_path);

        const file = std.fs.openFileAbsolute(idx_path, .{}) catch return;
        defer file.close();

        const stat = file.stat() catch return;
        const current_inode = stat.inode;

        if (self.index_inode) |prev_inode| {
            if (current_inode == prev_inode) return;
        } else {
            // No previous inode recorded — nothing to compare against
            return;
        }

        // Inode changed: reload the index
        const data = self.allocator.alloc(u8, stat.size) catch return;
        const bytes_read = file.readAll(data) catch {
            self.allocator.free(data);
            return;
        };
        if (bytes_read != stat.size) {
            self.allocator.free(data);
            return;
        }

        self.loadIndex(data) catch {
            self.allocator.free(data);
            return;
        };
        self.index_inode = current_inode;
    }
};
