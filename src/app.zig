const std = @import("std");
const types = @import("core/types.zig");
const navigator_mod = @import("core/navigator.zig");
const pins_mod = @import("core/pins.zig");
const folder_colors_mod = @import("core/folder_colors.zig");
const runtime = @import("core/runtime.zig");
const filter_store_mod = @import("core/filter_store.zig");
const filters_mod = @import("core/filters.zig");
const fs_provider = @import("core/fs_provider.zig");
const reader_mod = @import("index/reader.zig");
const search_mod = @import("index/search.zig");
const config = @import("config/config.zig");
const user_config_mod = @import("config/user_config.zig");

/// Reference-counted index snapshot. Allows background search threads
/// to hold a reference while the main thread swaps in a new index.
pub const IndexSnapshot = struct {
    data: []const u8,
    reader: reader_mod.IndexReader,
    ref_count: std.atomic.Value(u32),
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, data: []const u8) !*IndexSnapshot {
        const snap = try allocator.create(IndexSnapshot);
        snap.* = .{
            .data = data,
            .reader = try reader_mod.IndexReader.init(allocator, data),
            .ref_count = std.atomic.Value(u32).init(1),
            .allocator = allocator,
        };
        return snap;
    }

    pub fn retain(self: *IndexSnapshot) *IndexSnapshot {
        _ = self.ref_count.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *IndexSnapshot) void {
        if (self.ref_count.fetchSub(1, .release) == 1) {
            _ = self.ref_count.load(.acquire);
            var r = self.reader;
            r.deinit();
            self.allocator.free(self.data);
            self.allocator.destroy(self);
        }
    }
};

pub const App = struct {
    navigator: navigator_mod.Navigator,
    pin_manager: pins_mod.PinManager,
    folder_color_manager: folder_colors_mod.FolderColorManager,
    filter_store: filter_store_mod.FilterStore,
    user_config: user_config_mod.UserConfig,
    fs: fs_provider.FileSystemProvider,
    index_snapshot: ?*IndexSnapshot,
    allocator: std.mem.Allocator,
    pins_path: ?[]const u8,
    folder_colors_path: ?[]const u8,
    filters_path: ?[]const u8,
    config_path: ?[]const u8,
    index_inode: ?u64 = null,
    last_index_check: i128 = 0,

    pub fn init(allocator: std.mem.Allocator, fs: fs_provider.FileSystemProvider, initial_path: []const u8) !App {
        const pins_path = config.pinsPath(allocator) catch null;
        const folder_colors_path = config.folderColorsPath(allocator) catch null;
        const filters_path = config.filtersPath(allocator) catch null;
        const config_path = config.configPath(allocator) catch null;
        errdefer if (pins_path) |pp| allocator.free(pp);
        errdefer if (folder_colors_path) |path| allocator.free(path);
        errdefer if (filters_path) |path| allocator.free(path);
        errdefer if (config_path) |path| allocator.free(path);

        var app = App{
            .navigator = try navigator_mod.Navigator.init(allocator, initial_path),
            .pin_manager = pins_mod.PinManager.init(allocator, pins_path),
            .folder_color_manager = folder_colors_mod.FolderColorManager.init(allocator, folder_colors_path),
            .filter_store = filter_store_mod.FilterStore.init(allocator, filters_path),
            .user_config = user_config_mod.UserConfig.init(allocator, config_path),
            .fs = fs,
            .index_snapshot = null,
            .allocator = allocator,
            .pins_path = pins_path,
            .folder_colors_path = folder_colors_path,
            .filters_path = filters_path,
            .config_path = config_path,
        };

        app.pin_manager.load() catch {
            app.pin_manager.loadDefaults() catch {};
        };
        app.folder_color_manager.load() catch {};
        app.filter_store.load() catch {};
        app.user_config.load();

        return app;
    }

    pub fn deinit(self: *App) void {
        self.navigator.deinit();
        self.pin_manager.deinit();
        self.folder_color_manager.deinit();
        self.filter_store.deinit();
        self.user_config.deinit();
        if (self.index_snapshot) |snap| snap.release();
        if (self.pins_path) |pp| self.allocator.free(pp);
        if (self.folder_colors_path) |path| self.allocator.free(path);
        if (self.filters_path) |path| self.allocator.free(path);
        if (self.config_path) |path| self.allocator.free(path);
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

    // Search
    pub fn search(
        self: *App,
        query: []const u8,
        category: ?types.FileCategory,
        filter_criteria: []const filters_mod.FilterCriterion,
        scope: []const u8,
        max_depth: u32,
    ) ![]search_mod.SearchResult {
        if (self.index_snapshot) |snap| {
            return search_mod.search(self.allocator, &snap.reader, .{
                .query = query,
                .category = category,
                .filters = filter_criteria,
                .scope = scope,
                .max_depth = max_depth,
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

    // Folder appearance
    pub fn getFolderColor(self: *const App, path: []const u8) ?folder_colors_mod.FolderColor {
        return self.folder_color_manager.getColor(path);
    }

    pub fn setFolderColor(self: *App, path: []const u8, color: folder_colors_mod.FolderColor) !void {
        try self.folder_color_manager.setColor(path, color);
        self.folder_color_manager.save() catch {};
    }

    pub fn clearFolderColor(self: *App, path: []const u8) void {
        if (self.folder_color_manager.clearColor(path)) {
            self.folder_color_manager.save() catch {};
        }
    }

    // Open files/directories
    pub fn openFile(self: *App, path: []const u8) !void {
        _ = self;
        const argv: []const []const u8 = &.{ "open", path };
        _ = try std.process.spawn(runtime.io, .{ .argv = argv });
    }

    /// Open `path` in the user's preferred terminal. Tries each candidate in
    /// order (configured terminal first, then known terminals, Terminal.app
    /// last) and stops at the first `open -a` that exits 0. A missing app makes
    /// `open` exit non-zero without launching anything, so no stray window opens.
    pub fn openInTerminal(self: *App, path: []const u8) !void {
        var buf: [user_config_mod.max_candidates][]const u8 = undefined;
        const candidates = user_config_mod.terminalCandidates(&buf, self.user_config.terminal);

        for (candidates) |name| {
            const argv: []const []const u8 = &.{ "open", "-a", name, path };
            var child = std.process.spawn(runtime.io, .{ .argv = argv }) catch continue;
            const term = child.wait(runtime.io) catch continue;
            switch (term) {
                .exited => |code| if (code == 0) return,
                else => {},
            }
        }
    }

    // Index
    pub fn loadIndex(self: *App, data: []const u8) !void {
        const new_snap = try IndexSnapshot.create(self.allocator, data);
        if (self.index_snapshot) |old_snap| old_snap.release();
        self.index_snapshot = new_snap;
    }

    pub fn getIndexStatus(self: App) types.IndexStatus {
        if (self.index_snapshot) |_| return .ready;
        return .not_found;
    }

    /// Get the current index snapshot (retained — caller must release).
    pub fn getIndexSnapshot(self: *App) ?*IndexSnapshot {
        if (self.index_snapshot) |snap| return snap.retain();
        return null;
    }

    /// Check if the index file has changed on disk and reload it if so.
    /// Only performs the stat check every 5 seconds to avoid excessive syscalls.
    /// Returns true only when a new index was actually loaded, so the caller can
    /// re-query and drop rows that borrow into the now-replaced snapshot.
    pub fn checkForIndexUpdate(self: *App) bool {
        const check_interval_ns: i128 = 5 * std.time.ns_per_s;
        const now = runtime.nowNanos();
        if (now - self.last_index_check < check_interval_ns) return false;
        self.last_index_check = now;

        const idx_path = config.indexPath(self.allocator) catch return false;
        defer self.allocator.free(idx_path);

        const stat = std.Io.Dir.cwd().statFile(runtime.io, idx_path, .{}) catch return false;
        const current_inode = stat.inode;

        if (self.index_inode) |prev_inode| {
            if (current_inode == prev_inode) return false;
        } else {
            // No previous inode recorded — nothing to compare against
            return false;
        }

        // Inode changed: reload the index
        const data = runtime.readFileAlloc(self.allocator, idx_path, .unlimited) catch return false;

        self.loadIndex(data) catch {
            self.allocator.free(data);
            return false;
        };
        self.index_inode = current_inode;
        return true;
    }
};
