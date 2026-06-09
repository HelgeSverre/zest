const std = @import("std");
const types = @import("core/types.zig");
const navigator_mod = @import("core/navigator.zig");
const user_state_mod = @import("core/user_state.zig");
const runtime = @import("core/runtime.zig");
const filters_mod = @import("core/filters.zig");
const fs_provider = @import("core/fs_provider.zig");
const search_mod = @import("index/search.zig");
const session_mod = @import("index/session.zig");
const config = @import("config/config.zig");
const user_config_mod = @import("config/user_config.zig");

pub const App = struct {
    navigator: navigator_mod.Navigator,
    user_state: user_state_mod.UserState,
    fs: fs_provider.FileSystemProvider,
    session_index: session_mod.SessionIndex,
    allocator: std.mem.Allocator,

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
            .user_state = user_state_mod.UserState.init(allocator, pins_path, folder_colors_path, filters_path, config_path),
            .fs = fs,
            .session_index = session_mod.SessionIndex.init(allocator),
            .allocator = allocator,
        };

        app.user_state.loadAll();

        return app;
    }

    pub fn deinit(self: *App) void {
        self.navigator.deinit();
        self.user_state.deinit();
        self.session_index.deinit();
        if (self.user_state.pins_path) |pp| self.allocator.free(pp);
        if (self.user_state.folder_colors_path) |path| self.allocator.free(path);
        if (self.user_state.filters_path) |path| self.allocator.free(path);
        if (self.user_state.config_path) |path| self.allocator.free(path);
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
        return self.session_index.search(self.allocator, .{
            .query = query,
            .category = category,
            .filters = filter_criteria,
            .scope = scope,
            .max_depth = max_depth,
        });
    }

    // Pins
    pub fn addPin(self: *App, name: []const u8, path: []const u8) !void {
        try self.user_state.addPin(name, path);
        self.user_state.savePins() catch {};
    }

    pub fn removePin(self: *App, path: []const u8) void {
        _ = self.user_state.removePin(path);
        self.user_state.savePins() catch {};
    }

    pub fn getPins(self: App) []const types.Pin {
        return self.user_state.getPins();
    }

    // Folder appearance
    pub fn getFolderColor(self: *const App, path: []const u8) ?user_state_mod.FolderColor {
        return self.user_state.getFolderColor(path);
    }

    pub fn setFolderColor(self: *App, path: []const u8, color: user_state_mod.FolderColor) !void {
        try self.user_state.setFolderColor(path, color);
        self.user_state.saveFolderColors() catch {};
    }

    pub fn clearFolderColor(self: *App, path: []const u8) void {
        if (self.user_state.clearFolderColor(path)) {
            self.user_state.saveFolderColors() catch {};
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
        const candidates = user_config_mod.terminalCandidates(&buf, self.user_state.getTerminal());

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

    // Index delegation
    pub fn getIndexStatus(self: App) types.IndexStatus {
        return self.session_index.status();
    }

    pub fn getIndexSnapshot(self: *App) ?*session_mod.IndexSnapshot {
        return self.session_index.snapshot();
    }

    pub fn checkForIndexUpdate(self: *App) bool {
        return self.session_index.checkForUpdate();
    }
};
