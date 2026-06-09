const std = @import("std");
const objc = @import("objc.zig");
const types = @import("../core/types.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const session_mod = @import("../index/session.zig");
const user_state_mod = @import("../core/user_state.zig");
const filters_mod = @import("../core/filters.zig");
const query_parser = @import("../core/query_parser.zig");
const search_mod = @import("../index/search.zig");
const async_search_mod = @import("../core/async_search.zig");
const window = @import("window.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const runtime = @import("../core/runtime.zig");

const c = @cImport({
    @cInclude("time.h");
});

const FolderColorPreset = struct {
    title: []const u8,
    tag: i64,
    color: user_state_mod.FolderColor,
};

const folder_color_presets = [_]FolderColorPreset{
    .{ .title = "Blue", .tag = 1, .color = .{ .red = 111, .green = 168, .blue = 246 } },
    .{ .title = "Green", .tag = 2, .color = .{ .red = 122, .green = 184, .blue = 126 } },
    .{ .title = "Yellow", .tag = 3, .color = .{ .red = 214, .green = 180, .blue = 89 } },
    .{ .title = "Orange", .tag = 4, .color = .{ .red = 209, .green = 141, .blue = 84 } },
    .{ .title = "Red", .tag = 5, .color = .{ .red = 205, .green = 116, .blue = 108 } },
    .{ .title = "Pink", .tag = 6, .color = .{ .red = 196, .green = 121, .blue = 166 } },
    .{ .title = "Purple", .tag = 7, .color = .{ .red = 152, .green = 136, .blue = 215 } },
};

// ---------------------------------------------------------------------------
// Global application state (single-window app)
// ---------------------------------------------------------------------------

/// Active column sort for the file list. Persists for the session.
pub const SortState = struct {
    column: search_mod.SortColumn,
    ascending: bool,
};

pub const AppState = struct {
    app: *App,
    allocator: std.mem.Allocator,
    async_search: async_search_mod.AsyncSearch,
    // UI references
    window_id: objc.id = null,
    table_view: objc.id = null,
    sidebar_view: objc.id = null,
    search_field: objc.id = null,
    path_field: objc.id = null,
    category_popup: objc.id = null,
    file_context_menu: objc.id = null,
    sidebar_context_menu: objc.id = null,
    debounce_timer: objc.id = null,
    show_full_path_item: objc.id = null,
    folders_on_top_item: objc.id = null,
    empty_label: objc.id = null,
    // Filter bar
    filter_bar: objc.id = null,
    split_view: objc.id = null,
    active_filters: ?[]filters_mod.FilterCriterion = null,
    // The file list: a single owned result set for the current query
    // (a folder listing and a filter are both just queries against the index).
    rows: ?[]search_mod.SearchResult = null,
    // The snapshot whose mmap'd bytes `rows` borrows into (name/dir_path slices
    // point straight at IndexReader.data). Held with the exact lifetime of `rows`
    // so a background index reload can't free the buffer out from under the table.
    rows_snapshot: ?*session_mod.IndexSnapshot = null,
    sort: ?SortState = .{ .column = .name, .ascending = true },
    show_full_path: bool = false,
    /// Keep folders above files in the list regardless of sort column. On by
    /// default; toggle via View ▸ Keep Folders on Top. Session-only.
    folders_on_top: bool = true,

    pub fn init(self: *AppState, allocator: std.mem.Allocator, app: *App) void {
        self.* = .{
            .app = app,
            .allocator = allocator,
            .async_search = async_search_mod.AsyncSearch.init(allocator, .{
                .deliver = deliverSearchResults,
                .ctx = self,
            }),
            .window_id = null,
            .table_view = null,
            .sidebar_view = null,
            .search_field = null,
            .path_field = null,
            .category_popup = null,
            .file_context_menu = null,
            .sidebar_context_menu = null,
            .debounce_timer = null,
            .show_full_path_item = null,
            .folders_on_top_item = null,
            .empty_label = null,
            .filter_bar = null,
            .split_view = null,
            .active_filters = null,
            .rows = null,
            .rows_snapshot = null,
            .sort = .{ .column = .name, .ascending = true },
            .show_full_path = false,
            .folders_on_top = true,
        };
    }

    pub fn deinit(self: *AppState) void {
        // Cancel any in-flight background search
        self.async_search.cancel();
        if (self.debounce_timer) |timer| {
            objc.msgSendVoid(timer, "invalidate");
            self.debounce_timer = null;
        }
        if (self.rows) |rows| self.allocator.free(rows);
        if (self.rows_snapshot) |snap| snap.release();
        if (self.active_filters) |f| self.allocator.free(f);
    }
};

/// Delivery callback — called on the main thread by AsyncSearch with results.
fn deliverSearchResults(ctx: *anyopaque, results: ?[]search_mod.SearchResult, snapshot: ?*session_mod.IndexSnapshot) void {
    const s: *AppState = @ptrCast(@alignCast(ctx));
    if (s.rows) |old| s.allocator.free(old);
    if (s.rows_snapshot) |old| old.release();
    s.rows = results;
    s.rows_snapshot = snapshot;
    if (results) |rows| {
        if (s.sort) |srt| search_mod.sortResults(rows, srt.column, srt.ascending, s.folders_on_top);
    }
    updateEmptyState(s);
    if (s.table_view) |tv| objc.msgSendVoid(tv, "reloadData");
}

pub var state: ?*AppState = null;

// ---------------------------------------------------------------------------
// Class registration
// ---------------------------------------------------------------------------

var classes_registered: bool = false;

pub fn registerAllClasses() void {
    if (classes_registered) return;
    classes_registered = true;

    const NSObject = objc.getClass("NSObject") orelse @panic("NSObject not found");

    // ZestAppDelegate
    {
        const cls = objc.allocateClassPair(NSObject, "ZestAppDelegate") orelse @panic("Failed to create ZestAppDelegate");
        _ = objc.addMethod(cls, "applicationDidFinishLaunching:", appDidFinishLaunching, "v@:@");
        _ = objc.addMethod(cls, "applicationShouldTerminateAfterLastWindowClosed:", appShouldTerminate, "B@:@");
        _ = objc.addMethod(cls, "backAction:", backAction, "v@:@");
        _ = objc.addMethod(cls, "forwardAction:", forwardAction, "v@:@");
        _ = objc.addMethod(cls, "upAction:", upAction, "v@:@");
        _ = objc.addMethod(cls, "openItem:", openItemAction, "v@:@");
        _ = objc.addMethod(cls, "openSelection:", openSelectionAction, "v@:@");
        _ = objc.addMethod(cls, "searchAction:", searchAction, "v@:@");
        _ = objc.addMethod(cls, "debouncedSearchFire:", debouncedSearchFire, "v@:@");
        _ = objc.addMethod(cls, "focusSearch:", focusSearchAction, "v@:@");
        _ = objc.addMethod(cls, "pathAction:", pathAction, "v@:@");
        _ = objc.addMethod(cls, "sidebarClicked:", sidebarClickedAction, "v@:@");
        _ = objc.addMethod(cls, "pollIndex:", pollIndexAction, "v@:@");
        // NSSplitViewDelegate: keep both panes from collapsing to zero width.
        _ = objc.addMethod(cls, "splitView:constrainMinCoordinate:ofSubviewAt:", splitConstrainMin, "d@:@dq");
        _ = objc.addMethod(cls, "splitView:constrainMaxCoordinate:ofSubviewAt:", splitConstrainMax, "d@:@dq");
        _ = objc.addMethod(cls, "copyPath:", copyPathAction, "v@:@");
        _ = objc.addMethod(cls, "openInTerminal:", openInTerminalAction, "v@:@");
        _ = objc.addMethod(cls, "pinFolder:", pinFolderAction, "v@:@");
        _ = objc.addMethod(cls, "unpinFolder:", unpinFolderAction, "v@:@");
        _ = objc.addMethod(cls, "setFolderColor:", setFolderColorAction, "v@:@");
        _ = objc.addMethod(cls, "goToContainingFolder:", goToContainingFolderAction, "v@:@");
        _ = objc.addMethod(cls, "removeFilter:", removeFilterAction, "v@:@");
        _ = objc.addMethod(cls, "saveFilter:", saveFilterAction, "v@:@");
        _ = objc.addMethod(cls, "loadSavedFilter:", loadSavedFilterAction, "v@:@");
        _ = objc.addMethod(cls, "quickFilterSelected:", quickFilterSelectedAction, "v@:@");
        _ = objc.addMethod(cls, "toggleShowFullPath:", toggleShowFullPathAction, "v@:@");
        _ = objc.addMethod(cls, "toggleFoldersOnTop:", toggleFoldersOnTopAction, "v@:@");
        _ = objc.addMethod(cls, "menuNeedsUpdate:", menuNeedsUpdate, "v@:@");
        objc.registerClassPair(cls);
    }

    // ZestTableDataSource
    {
        const cls = objc.allocateClassPair(NSObject, "ZestTableDataSource") orelse @panic("Failed to create ZestTableDataSource");
        _ = objc.addMethod(cls, "numberOfRowsInTableView:", tableNumberOfRows, "q@:@");
        _ = objc.addMethod(cls, "tableView:viewForTableColumn:row:", tableViewForColumn, "@@:@@q");
        _ = objc.addMethod(cls, "tableView:rowViewForRow:", tableRowView, "@@:@q");
        _ = objc.addMethod(cls, "tableView:sortDescriptorsDidChange:", tableSortDescriptorsDidChange, "v@:@@");
        objc.registerClassPair(cls);
    }

    // ZestSidebarDataSource
    {
        const cls = objc.allocateClassPair(NSObject, "ZestSidebarDataSource") orelse @panic("Failed to create ZestSidebarDataSource");
        _ = objc.addMethod(cls, "numberOfRowsInTableView:", sidebarNumberOfRows, "q@:@");
        _ = objc.addMethod(cls, "tableView:objectValueForTableColumn:row:", sidebarObjectValue, "@@:@@q");
        _ = objc.addMethod(cls, "tableView:viewForTableColumn:row:", sidebarViewForColumn, "@@:@@q");
        _ = objc.addMethod(cls, "tableView:rowViewForRow:", tableRowView, "@@:@q");
        objc.registerClassPair(cls);
    }

    // ZestTableView — NSTableView subclass adding Return/Enter to open the
    // selected row (double-click already opens via setDoubleAction:).
    {
        const NSTableView = objc.getClass("NSTableView") orelse @panic("NSTableView not found");
        const cls = objc.allocateClassPair(NSTableView, "ZestTableView") orelse @panic("Failed to create ZestTableView");
        _ = objc.addMethod(cls, "keyDown:", fileListKeyDown, "v@:@");
        objc.registerClassPair(cls);
    }

    // ZestRowView — NSTableRowView subclass that draws the themed selection
    // pill, so both the file list and sidebar use theme.selection instead of
    // the OS accent color.
    {
        const NSTableRowView = objc.getClass("NSTableRowView") orelse @panic("NSTableRowView not found");
        const cls = objc.allocateClassPair(NSTableRowView, "ZestRowView") orelse @panic("Failed to create ZestRowView");
        _ = objc.addMethod(cls, "drawSelectionInRect:", drawRowSelection, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}");
        objc.registerClassPair(cls);
    }
}

// ---------------------------------------------------------------------------
// AppDelegate callbacks
// ---------------------------------------------------------------------------

fn appDidFinishLaunching(_self: objc.id, _cmd: objc.SEL, _notification: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _notification;
    window.createMainWindow();

    // Activate AFTER window is created — required for non-bundled apps to come to front
    const NSApp = objc.msgSend(objc.getClass("NSApplication").?, "sharedApplication");
    objc.msgSendVoidWith1(bool, NSApp, "activateIgnoringOtherApps:", true);
}

fn appShouldTerminate(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) bool {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    return true;
}

fn backAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    _ = s.app.goBack() catch return;
    navigateRefresh(s);
}

fn forwardAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    _ = s.app.goForward() catch return;
    navigateRefresh(s);
}

fn upAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    _ = s.app.goUp() catch return;
    navigateRefresh(s);
}

fn openItemAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    // A double-click on the column header arrives here with the table as sender;
    // reject it so header clicks only sort and never open the row beneath.
    if (s.table_view) |tv| {
        if (sender == tv and !doubleClickHitDataRow(tv)) return;
    }
    const path = contextPathFromSenderOrSelection(s, sender) orelse return;
    defer s.allocator.free(path);
    openPath(s, path);
}

fn openSelectionAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    openItemAction(_self, _cmd, sender);
}

fn searchAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;

    // Invalidate any pending debounce timer
    if (s.debounce_timer) |timer| {
        objc.msgSendVoid(timer, "invalidate");
        s.debounce_timer = null;
    }

    // Empty field — re-list the current folder immediately (no debounce).
    const nsstr = objc.msgSend(sender, "stringValue");
    const len = objc.msgSendI64(nsstr, "length");
    if (len == 0) {
        runQuery(s);
        return;
    }

    // Schedule debounced search (150ms delay)
    const NSApp = objc.msgSend(objc.getClass("NSApplication").?, "sharedApplication");
    const delegate_obj = objc.msgSend(NSApp, "delegate");
    const timer_fn = objc.msgSendFn(*const fn (objc.id, objc.SEL, f64, objc.id, objc.SEL, objc.id, bool) callconv(.c) objc.id);
    const timer = timer_fn(
        objc.getClass("NSTimer").?,
        objc.sel("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
        @as(f64, 0.15), // 150ms debounce
        delegate_obj,
        objc.sel("debouncedSearchFire:"),
        @as(objc.id, null),
        false, // one-shot
    );
    s.debounce_timer = timer;
}

fn debouncedSearchFire(_self: objc.id, _cmd: objc.SEL, _timer: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _timer;
    const s = state orelse return;
    s.debounce_timer = null;
    runQuery(s);
}

fn focusSearchAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    const field = s.search_field orelse return;
    focusAndSelectView(s.window_id, field);
}

fn pathAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    const field = if (sender != null) sender else s.path_field orelse return;
    const nsstr = objc.msgSend(field, "stringValue");
    const raw_path = objc.NSString.toSlice(s.allocator, nsstr) catch return;
    defer s.allocator.free(raw_path);

    const resolved = resolveEnteredPath(s, raw_path) orelse {
        updatePathField();
        focusAndSelectView(s.window_id, field);
        return;
    };
    defer s.allocator.free(resolved);

    if (s.app.fs.isDir(resolved)) {
        s.app.openDirectory(resolved) catch {
            updatePathField();
            focusAndSelectView(s.window_id, field);
            return;
        };
        navigateRefresh(s);
        return;
    }

    if (s.app.fs.exists(resolved)) {
        s.app.openFile(resolved) catch {};
    }

    updatePathField();
}

/// Single-click on a sidebar pin — navigate to it. Wired as the table's action
/// (not the selection-change notification) so it also fires when the user
/// re-clicks the already-selected pin after navigating away by other means.
fn sidebarClickedAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    const sv = s.sidebar_view orelse return;
    const row = objc.msgSendI64(sv, "clickedRow");
    if (row < 0) return;
    const pins = s.app.getPins();
    const idx: usize = @intCast(row);
    if (idx >= pins.len) return;
    s.app.openDirectory(pins[idx].path) catch return;
    navigateRefresh(s);
}

/// NSSplitViewDelegate: leftmost the divider may travel (sidebar min width).
fn splitConstrainMin(_self: objc.id, _cmd: objc.SEL, _split: objc.id, proposed: f64, _index: i64) callconv(.c) f64 {
    _ = _self;
    _ = _cmd;
    _ = _split;
    _ = _index;
    const min_sidebar: f64 = 150;
    return if (proposed < min_sidebar) min_sidebar else proposed;
}

/// NSSplitViewDelegate: rightmost the divider may travel (file-list min width).
fn splitConstrainMax(_self: objc.id, _cmd: objc.SEL, split_view: objc.id, proposed: f64, _index: i64) callconv(.c) f64 {
    _ = _self;
    _ = _cmd;
    _ = _index;
    const min_filelist: f64 = 400;
    const f = window.getFrame(split_view);
    const max_x = f.size.width - min_filelist;
    return if (proposed > max_x) max_x else proposed;
}

/// Upper bound on rows shown in the file list. Folder listings need far more
/// than the old global-search cap of 100, but a bound still guards memory for a
/// broad recursive filter over a large index.
const file_list_max_results: u32 = 100_000;

/// Re-run the file list as a single query against the index for the current
/// scope (`Navigator.current`), reading the free-text + qualifiers from the
/// search field. This is the *one* place that decides depth: an empty free-text
/// query is a depth-1 folder listing; any free text searches the whole subtree.
fn runQuery(s: *AppState) void {
    // Read the search field (empty when absent or unreadable).
    var raw_query: []const u8 = "";
    var raw_owned: ?[]const u8 = null;
    if (s.search_field) |field| {
        const nsstr = objc.msgSend(field, "stringValue");
        if (objc.NSString.toSlice(s.allocator, nsstr)) |slice| {
            raw_owned = slice;
            raw_query = slice;
        } else |_| {}
    }
    defer if (raw_owned) |b| s.allocator.free(b);

    const parsed = query_parser.parse(s.allocator, raw_query) catch return;

    // The pill bar reflects the active qualifiers (ownership moves here).
    if (s.active_filters) |f| s.allocator.free(f);
    s.active_filters = parsed.filters_list;
    updateFilterBar(s);

    // A bare folder listing (nothing typed at all) is depth-1; any free text OR
    // an active qualifier filters the whole subtree under the current scope.
    const max_depth: u32 = if (parsed.text.len == 0 and parsed.filters_list.len == 0)
        1
    else
        std.math.maxInt(u32);

    const snapshot = s.app.getIndexSnapshot() orelse {
        s.allocator.free(parsed.text);
        // No index loaded — empty the list and show a status hint.
        if (s.rows) |r| s.allocator.free(r);
        s.rows = null;
        if (s.rows_snapshot) |snap| snap.release();
        s.rows_snapshot = null;
        updateEmptyState(s);
        if (s.table_view) |tv| objc.msgSendVoid(tv, "reloadData");
        return;
    };
    // submitSearch retains its own snapshot ref for the background thread;
    // release the ref getIndexSnapshot handed us once we return.
    defer snapshot.release();

    // Background thread takes ownership of a snapshot ref and copies of the
    // query/filters/scope.
    s.async_search.submitSearch(
        snapshot,
        parsed.text,
        null,
        parsed.filters_list,
        s.app.navigator.current,
        max_depth,
        file_list_max_results,
    );
    s.allocator.free(parsed.text);
}

/// Apply a scope change: clear the search field, refresh chrome, and re-list the
/// new folder. Replaces the old browse/search "leave search mode" dance.
fn navigateRefresh(s: *AppState) void {
    s.async_search.cancel();
    if (s.debounce_timer) |timer| {
        objc.msgSendVoid(timer, "invalidate");
        s.debounce_timer = null;
    }
    if (s.search_field) |field| {
        objc.msgSendVoidWith1(objc.id, field, "setStringValue:", objc.NSString.fromSlice(""));
    }
    updatePathField();
    if (s.sidebar_view) |sv| {
        objc.msgSendVoid(sv, "reloadData");
        syncSidebarSelection(s);
    }
    runQuery(s);
}

/// View ▸ Show Full Path (⌘⇧P): toggle absolute vs scope-relative names.
fn toggleShowFullPathAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    s.show_full_path = !s.show_full_path;
    const item = if (sender != null) sender else s.show_full_path_item;
    if (item) |it| {
        objc.msgSendVoidWith1(i64, it, "setState:", @as(i64, if (s.show_full_path) 1 else 0));
    }
    if (s.table_view) |tv| objc.msgSendVoid(tv, "reloadData");
}

/// View ▸ Keep Folders on Top: toggle whether directories sort above files,
/// then re-sort the current list in place.
fn toggleFoldersOnTopAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    s.folders_on_top = !s.folders_on_top;
    const item = if (sender != null) sender else s.folders_on_top_item;
    if (item) |it| {
        objc.msgSendVoidWith1(i64, it, "setState:", @as(i64, if (s.folders_on_top) 1 else 0));
    }
    if (s.rows) |rows| {
        if (s.sort) |srt| search_mod.sortResults(rows, srt.column, srt.ascending, s.folders_on_top);
    }
    if (s.table_view) |tv| objc.msgSendVoid(tv, "reloadData");
}

fn pollIndexAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    // A reload swaps the index snapshot; re-query so the visible rows borrow into
    // the new buffer instead of the freed one, then redraw with fresh data.
    if (s.app.checkForIndexUpdate()) refreshAll();
}

fn copyPathAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    const path = contextPathFromSenderOrSelection(s, _sender) orelse return;
    defer s.allocator.free(path);
    writePathToPasteboard(path);
}

fn openInTerminalAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    const path = contextPathFromSenderOrSelection(s, sender) orelse return;
    defer s.allocator.free(path);

    const terminal_path = if (s.app.fs.isDir(path))
        path
    else
        std.fs.path.dirname(path) orelse s.app.currentPath();
    s.app.openInTerminal(terminal_path) catch {};
}

fn pinFolderAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    const path = contextPathFromSenderOrSelection(s, sender) orelse return;
    defer s.allocator.free(path);
    if (!s.app.fs.isDir(path)) return;

    const basename = std.fs.path.basename(path);
    const name = if (basename.len > 0) basename else path;
    s.app.addPin(name, path) catch {};
    if (s.sidebar_view) |sv| objc.msgSendVoid(sv, "reloadData");
}

fn unpinFolderAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    const path = contextPathFromSenderOrSelection(s, sender) orelse return;
    defer s.allocator.free(path);
    s.app.removePin(path);
    if (s.sidebar_view) |sv| objc.msgSendVoid(sv, "reloadData");
    if (s.table_view) |tv| objc.msgSendVoid(tv, "reloadData");
}

fn setFolderColorAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    const path = representedPathFromSender(s, sender) orelse contextPathFromSenderOrSelection(s, sender) orelse return;
    defer s.allocator.free(path);

    const tag = objc.msgSendI64(sender, "tag");
    if (tag == 0) {
        s.app.clearFolderColor(path);
    } else if (folderColorForTag(tag)) |color| {
        s.app.setFolderColor(path, color) catch return;
    } else {
        return;
    }

    if (s.sidebar_view) |sv| objc.msgSendVoid(sv, "reloadData");
    if (s.table_view) |tv| objc.msgSendVoid(tv, "reloadData");
}

fn goToContainingFolderAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    const dir_path = representedPathFromSender(s, sender) orelse {
        // Fallback: get from selected row
        const tv = s.table_view orelse return;
        const idx = preferredTableIndex(tv) orelse return;
        const rows = s.rows orelse return;
        if (idx >= rows.len) return;
        const path = s.allocator.dupe(u8, rows[idx].dir_path) catch return;
        defer s.allocator.free(path);
        s.app.openDirectory(path) catch return;
        navigateRefresh(s);
        return;
    };
    defer s.allocator.free(dir_path);
    s.app.openDirectory(dir_path) catch return;
    navigateRefresh(s);
}

fn removeFilterAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    const tag = objc.msgSendI64(sender, "tag");
    if (tag < 0) return;
    const idx: usize = @intCast(tag);

    // Remove the qualifier from the search field text
    const sf = s.search_field orelse return;
    const nsstr = objc.msgSend(sf, "stringValue");
    const current_text = objc.NSString.toSlice(s.allocator, nsstr) catch return;
    defer s.allocator.free(current_text);

    // Re-parse, remove filter at index, rebuild text
    var parsed = query_parser.parse(s.allocator, current_text) catch return;
    defer parsed.deinit();

    if (idx >= parsed.filters_list.len) return;

    // Rebuild the search string without the removed filter
    var new_parts: std.ArrayList(u8) = .empty;
    defer new_parts.deinit(s.allocator);

    if (parsed.text.len > 0) {
        new_parts.appendSlice(s.allocator, parsed.text) catch return;
    }

    for (parsed.filters_list, 0..) |f, i| {
        if (i == idx) continue;
        if (new_parts.items.len > 0) new_parts.append(s.allocator, ' ') catch return;
        var buf: [128]u8 = undefined;
        const formatted = filters_mod.formatCriterion(f, &buf);
        new_parts.appendSlice(s.allocator, formatted) catch return;
    }

    objc.msgSendVoidWith1(objc.id, sf, "setStringValue:", objc.NSString.fromSlice(new_parts.items));
    runQuery(s);
}

fn saveFilterAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    const sf = s.search_field orelse return;
    const nsstr = objc.msgSend(sf, "stringValue");
    const query_text = objc.NSString.toSlice(s.allocator, nsstr) catch return;
    defer s.allocator.free(query_text);
    if (query_text.len == 0) return;

    // Show save dialog using NSAlert with accessory text field
    const NSAlert = objc.getClass("NSAlert") orelse return;
    const alert = objc.init(objc.alloc(NSAlert));
    objc.msgSendVoidWith1(objc.id, alert, "setMessageText:", objc.NSString.fromSlice("Save Filter"));
    objc.msgSendVoidWith1(objc.id, alert, "setInformativeText:", objc.NSString.fromSlice("Enter a name for this filter:"));
    _ = objc.msgSendWith1(objc.id, alert, "addButtonWithTitle:", objc.NSString.fromSlice("Save"));
    _ = objc.msgSendWith1(objc.id, alert, "addButtonWithTitle:", objc.NSString.fromSlice("Cancel"));

    if (objc.getClass("NSTextField")) |NSTextField| {
        const input = objc.autorelease(objc.msgSendWith1(
            objc.CGRect,
            objc.alloc(NSTextField),
            "initWithFrame:",
            objc.CGRect.make(0, 0, 200, 24),
        ));
        objc.msgSendVoidWith1(objc.id, alert, "setAccessoryView:", input);

        const response = objc.msgSendI64(alert, "runModal");
        if (response == 1000) { // NSAlertFirstButtonReturn
            const name_ns = objc.msgSend(input, "stringValue");
            const name = objc.NSString.toSlice(s.allocator, name_ns) catch return;
            defer s.allocator.free(name);
            if (name.len > 0) {
                s.app.user_state.addSavedFilter(name, query_text) catch return;
                s.app.user_state.saveFilters() catch {};
            }
        }
    }
}

fn quickFilterSelectedAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    const qualifier = representedPathFromSender(s, sender) orelse return;
    defer s.allocator.free(qualifier);

    const sf = s.search_field orelse return;

    // Get current search text
    const nsstr = objc.msgSend(sf, "stringValue");
    const current = objc.NSString.toSlice(s.allocator, nsstr) catch return;
    defer s.allocator.free(current);

    // Append qualifier with space separator
    const new_text = if (current.len > 0)
        std.fmt.allocPrint(s.allocator, "{s} {s}", .{ current, qualifier }) catch return
    else
        s.allocator.dupe(u8, qualifier) catch return;
    defer s.allocator.free(new_text);

    objc.msgSendVoidWith1(objc.id, sf, "setStringValue:", objc.NSString.fromSlice(new_text));
    runQuery(s);
}

fn loadSavedFilterAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    const query = representedPathFromSender(s, sender) orelse return;
    defer s.allocator.free(query);

    const sf = s.search_field orelse return;
    objc.msgSendVoidWith1(objc.id, sf, "setStringValue:", objc.NSString.fromSlice(query));
    runQuery(s);
}

fn menuNeedsUpdate(_self: objc.id, _cmd: objc.SEL, menu: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    const s = state orelse return;
    clearMenu(menu);
    if (menu == s.file_context_menu) {
        rebuildFileContextMenu(s, menu);
    } else if (menu == s.sidebar_context_menu) {
        rebuildSidebarContextMenu(s, menu);
    }
}

// ---------------------------------------------------------------------------
// Table data source callbacks
// ---------------------------------------------------------------------------

fn tableNumberOfRows(_self: objc.id, _cmd: objc.SEL, _table: objc.id) callconv(.c) i64 {
    _ = _self;
    _ = _cmd;
    _ = _table;
    const s = state orelse return 0;
    if (s.rows) |rows| return @intCast(rows.len);
    return 0;
}

/// Source the display string for a non-name column ("size"/"modified"/"type").
/// The "name" column is rendered directly by tableViewForColumn (icon + label),
/// so it never reaches here.
fn tableObjectValueRow(s: *AppState, col_id: []const u8, idx: usize) objc.id {
    const rows = s.rows orelse return null;
    if (idx >= rows.len) return null;
    const result = rows[idx];

    if (std.mem.eql(u8, col_id, "size")) {
        if (result.kind == .directory) return objc.NSString.fromSlice("--");
        var buf: [32]u8 = undefined;
        const size_str = formatSize(result.size, &buf);
        return objc.NSString.fromSlice(size_str);
    } else if (std.mem.eql(u8, col_id, "modified")) {
        var buf: [32]u8 = undefined;
        return objc.NSString.fromSlice(formatDate(result.mtime, &buf));
    } else if (std.mem.eql(u8, col_id, "type")) {
        return objc.NSString.fromSlice(result.category.displayName());
    }
    return null;
}

fn tableViewForColumn(_self: objc.id, _cmd: objc.SEL, table: objc.id, column: objc.id, row: i64) callconv(.c) objc.id {
    _ = _self;
    _ = _cmd;
    const s = state orelse return null;
    if (row < 0) return null;
    const idx: usize = @intCast(row);

    const col_id_ns = objc.msgSend(column, "identifier");
    const col_id = objc.NSString.toSlice(s.allocator, col_id_ns) catch return null;
    defer s.allocator.free(col_id);

    if (std.mem.eql(u8, col_id, "name")) {
        const rows = s.rows orelse return null;
        if (idx >= rows.len) return null;
        const result = rows[idx];
        const full_path = std.fmt.allocPrint(s.allocator, "{s}/{s}", .{ result.dir_path, result.name }) catch return null;
        defer s.allocator.free(full_path);
        const title = search_mod.displayName(s.allocator, result, s.app.navigator.current, s.show_full_path) catch return null;
        defer s.allocator.free(title);
        return buildNameCell(table, column, "NameCell", title, full_path, result.kind, result.category, theme.file_row_height, theme.text_bright);
    }

    const value = tableObjectValueRow(s, col_id, idx);
    if (value == null) return null;

    const color = if (std.mem.eql(u8, col_id, "type"))
        theme.text_primary
    else
        theme.text_secondary;
    const alignment: i64 = if (std.mem.eql(u8, col_id, "size")) 2 else 0;
    return buildTextCell(table, column, "ValueCell", value, color, alignment, theme.file_row_height);
}

/// NSTableView delegate: a sort-descriptor change (header click) updates the
/// active sort, reorders the rows in place, and reloads.
fn tableSortDescriptorsDidChange(_self: objc.id, _cmd: objc.SEL, table_view: objc.id, _old: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _old;
    const s = state orelse return;
    const descriptors = objc.msgSend(table_view, "sortDescriptors");
    if (descriptors == null) return;
    if (objc.msgSendI64(descriptors, "count") <= 0) return;
    const desc = objc.msgSendWith1(i64, descriptors, "objectAtIndex:", @as(i64, 0));
    const key_ns = objc.msgSend(desc, "key");
    const key = objc.NSString.toSlice(s.allocator, key_ns) catch return;
    defer s.allocator.free(key);
    const ascending = objc.msgSendBool(desc, "ascending");
    const column = columnForKey(key) orelse return;
    s.sort = .{ .column = column, .ascending = ascending };
    if (s.rows) |rows| search_mod.sortResults(rows, column, ascending, s.folders_on_top);
    if (s.table_view) |tv| objc.msgSendVoid(tv, "reloadData");
}

fn columnForKey(key: []const u8) ?search_mod.SortColumn {
    if (std.mem.eql(u8, key, "name")) return .name;
    if (std.mem.eql(u8, key, "size")) return .size;
    if (std.mem.eql(u8, key, "modified")) return .mtime;
    if (std.mem.eql(u8, key, "type")) return .category;
    return null;
}

/// NSTableView delegate (file list + sidebar): hand back a ZestRowView so the
/// selection highlight is drawn with theme.selection instead of the OS accent.
fn tableRowView(_self: objc.id, _cmd: objc.SEL, _table: objc.id, _row: i64) callconv(.c) objc.id {
    _ = _self;
    _ = _cmd;
    _ = _table;
    _ = _row;
    const cls = objc.getClass("ZestRowView") orelse return null;
    return objc.autorelease(objc.init(objc.alloc(cls)));
}

/// ZestRowView.drawSelectionInRect: paint a themed rounded selection pill. Fully
/// replaces the default accent-colored highlight (we don't call super).
fn drawRowSelection(_self: objc.id, _cmd: objc.SEL, _rect: objc.CGRect) callconv(.c) void {
    _ = _cmd;
    _ = _rect;
    if (!objc.msgSendBool(_self, "isSelected")) return;
    const bounds = viewBounds(_self);
    const inset = objc.CGRect.make(
        theme.row_selection_inset,
        1,
        bounds.size.width - theme.row_selection_inset * 2,
        bounds.size.height - 2,
    );
    const NSBezierPath = objc.getClass("NSBezierPath") orelse return;
    const pathFn = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGRect, objc.CGFloat, objc.CGFloat) callconv(.c) objc.id);
    const path = pathFn(
        @as(objc.id, @ptrCast(NSBezierPath)),
        objc.sel("bezierPathWithRoundedRect:xRadius:yRadius:"),
        inset,
        theme.row_selection_radius,
        theme.row_selection_radius,
    );
    objc.msgSendVoid(window.makeNSColor(theme.selection), "set");
    objc.msgSendVoid(path, "fill");
}

fn viewBounds(view: objc.id) objc.CGRect {
    const func = objc.msgSendFn(*const fn (objc.id, objc.SEL) callconv(.c) objc.CGRect);
    return func(view, objc.sel("bounds"));
}

/// ZestTableView.keyDown: Return/Enter opens the selected row; every other key
/// (arrows, type-select, etc.) forwards to NSTableView's default handling.
fn fileListKeyDown(_self: objc.id, _cmd: objc.SEL, event: objc.id) callconv(.c) void {
    _ = _cmd;
    const ns_carriage_return: u32 = 0x0D;
    const ns_enter: u32 = 0x03;
    const chars = objc.msgSend(event, "charactersIgnoringModifiers");
    if (chars != null and objc.msgSendI64(chars, "length") > 0) {
        const first: u32 = @intCast(objc.msgSendI64With1(u64, chars, "characterAtIndex:", @as(u64, 0)));
        if (first == ns_carriage_return or first == ns_enter) {
            openSelectedRow();
            return;
        }
    }
    const NSTableView = objc.getClass("NSTableView") orelse return;
    objc.msgSendSuperVoidWith1(objc.id, _self, NSTableView, "keyDown:", event);
}

/// Open the file list's selected row (keyboard path — uses selectedRow directly,
/// bypassing the clicked-row/header double-click guard in openItemAction).
fn openSelectedRow() void {
    const s = state orelse return;
    const tv = s.table_view orelse return;
    const selected = objc.msgSendI64(tv, "selectedRow");
    if (selected < 0) return;
    const path = getPathForRow(s, @intCast(selected)) orelse return;
    defer s.allocator.free(path);
    openPath(s, path);
}

// ---------------------------------------------------------------------------
// Sidebar data source callbacks
// ---------------------------------------------------------------------------

fn sidebarNumberOfRows(_self: objc.id, _cmd: objc.SEL, _table: objc.id) callconv(.c) i64 {
    _ = _self;
    _ = _cmd;
    _ = _table;
    const s = state orelse return 0;
    return @intCast(s.app.getPins().len);
}

fn sidebarObjectValue(_self: objc.id, _cmd: objc.SEL, _table: objc.id, _column: objc.id, row: i64) callconv(.c) objc.id {
    _ = _self;
    _ = _cmd;
    _ = _table;
    _ = _column;
    const s = state orelse return null;
    if (row < 0) return null;
    const pins = s.app.getPins();
    const idx: usize = @intCast(row);
    if (idx >= pins.len) return null;
    const pin = pins[idx];
    return objc.NSString.fromSlice(pin.name);
}

fn sidebarViewForColumn(_self: objc.id, _cmd: objc.SEL, table: objc.id, column: objc.id, row: i64) callconv(.c) objc.id {
    _ = _self;
    _ = _cmd;
    const s = state orelse return null;
    if (row < 0) return null;

    const pins = s.app.getPins();
    const idx: usize = @intCast(row);
    if (idx >= pins.len) return null;
    const pin = pins[idx];
    return buildNameCell(table, column, "SidebarCell", pin.name, pin.path, .directory, .uncategorized, theme.sidebar_row_height, theme.text_primary);
}

/// Keep the sidebar highlight in sync with the current folder: highlight the pin
/// whose path matches the current scope, or clear the selection when none does.
fn syncSidebarSelection(s: *AppState) void {
    const sv = s.sidebar_view orelse return;
    const pins = s.app.getPins();
    const current = s.app.navigator.current;
    for (pins, 0..) |pin, i| {
        if (std.mem.eql(u8, pin.path, current)) {
            const NSIndexSet = objc.getClass("NSIndexSet") orelse return;
            const idx_set = objc.msgSendWith1(u64, @as(objc.id, @ptrCast(NSIndexSet)), "indexSetWithIndex:", @as(u64, @intCast(i)));
            objc.msgSendVoidWith2(objc.id, bool, sv, "selectRowIndexes:byExtendingSelection:", idx_set, false);
            return;
        }
    }
    objc.msgSendVoidWith1(objc.id, sv, "deselectAll:", null);
}

fn buildTextCell(table: objc.id, column: objc.id, identifier_text: []const u8, value: objc.id, color: @TypeOf(theme.text_primary), alignment: i64, height: f64) objc.id {
    const width = objc.msgSendF64(column, "width");
    const frame = objc.CGRect.make(0, 0, width, height);
    const cell = reuseOrCreateCell(table, identifier_text, frame);
    if (cell == null) return null;

    var label = objc.msgSend(cell, "textField");
    if (label == null) {
        label = makeLabel(objc.NSString.fromSlice(""), color);
        if (label == null) return cell;
        objc.msgSendVoidWith1(objc.id, cell, "setTextField:", label);
        objc.msgSendVoidWith1(objc.id, cell, "addSubview:", label);
    }

    const label_width = if (width > 20) width - 20 else width;
    objc.msgSendVoidWith1(objc.id, label, "setStringValue:", value);
    objc.msgSendVoidWith1(objc.id, label, "setTextColor:", window.makeNSColor(color));
    objc.msgSendVoidWith1(objc.id, label, "setFont:", window.makeSystemFont(theme.font_size_secondary));
    objc.msgSendVoidWith1(objc.CGRect, label, "setFrame:", objc.CGRect.make(10, 6, label_width, height - 12));
    objc.msgSendVoidWith1(i64, label, "setAlignment:", alignment);
    objc.msgSendVoidWith1(bool, label, "setUsesSingleLineMode:", true);
    objc.msgSendVoidWith1(i64, label, "setLineBreakMode:", @as(i64, 4));
    return cell;
}

fn buildNameCell(table: objc.id, column: objc.id, identifier_text: []const u8, title: []const u8, full_path: []const u8, kind: types.FileKind, category: types.FileCategory, height: f64, color: @TypeOf(theme.text_primary)) objc.id {
    const width = objc.msgSendF64(column, "width");
    const frame = objc.CGRect.make(0, 0, width, height);
    const cell = reuseOrCreateCell(table, identifier_text, frame);
    if (cell == null) return null;

    var image_view = objc.msgSend(cell, "imageView");
    if (image_view == null) {
        image_view = makeView("NSImageView", objc.CGRect.make(8, 5, height - 10, height - 10));
        if (image_view != null) {
            objc.msgSendVoidWith1(objc.id, cell, "setImageView:", image_view);
            objc.msgSendVoidWith1(objc.id, cell, "addSubview:", image_view);
        }
    }

    if (image_view) |iv| {
        objc.msgSendVoidWith1(objc.CGRect, iv, "setFrame:", objc.CGRect.make(8, 5, height - 10, height - 10));
        const color_override = if (kind == .directory)
            (state orelse return cell).app.getFolderColor(full_path)
        else
            null;
        const icon = icons.symbolImage(icons.fileSymbolName(kind, category), height - 14, 0.0, 1);
        if (icon != null) {
            icons.applyImage(iv, icon, icons.iconTint(kind, category, color_override), height - 10);
            objc.msgSendVoidWith1(i64, iv, "setImageScaling:", @as(i64, 2));
        }
    }

    var label = objc.msgSend(cell, "textField");
    if (label == null) {
        label = makeLabel(objc.NSString.fromSlice(""), color);
        if (label != null) {
            objc.msgSendVoidWith1(objc.id, cell, "setTextField:", label);
            objc.msgSendVoidWith1(objc.id, cell, "addSubview:", label);
        }
    }

    if (label) |field| {
        const text_x = height + 6;
        const text_width = if (width > text_x + 12) width - text_x - 12 else width;
        objc.msgSendVoidWith1(objc.id, field, "setStringValue:", objc.NSString.fromSlice(title));
        objc.msgSendVoidWith1(objc.id, field, "setTextColor:", window.makeNSColor(color));
        objc.msgSendVoidWith1(objc.id, field, "setFont:", window.makeSystemFont(theme.font_size_row));
        objc.msgSendVoidWith1(objc.CGRect, field, "setFrame:", objc.CGRect.make(text_x, 6, text_width, height - 12));
        objc.msgSendVoidWith1(bool, field, "setUsesSingleLineMode:", true);
        objc.msgSendVoidWith1(i64, field, "setLineBreakMode:", @as(i64, 4));
    }

    return cell;
}

fn reuseOrCreateCell(table: objc.id, identifier_text: []const u8, frame: objc.CGRect) objc.id {
    const identifier = objc.NSString.fromSlice(identifier_text);
    const reused = objc.msgSendWith2(objc.id, objc.id, table, "makeViewWithIdentifier:owner:", identifier, null);
    if (reused != null) {
        objc.msgSendVoidWith1(objc.CGRect, reused, "setFrame:", frame);
        return reused;
    }

    const cell = makeView("NSTableCellView", frame);
    if (cell != null) {
        objc.msgSendVoidWith1(objc.id, cell, "setIdentifier:", identifier);
    }
    return cell;
}

fn makeView(class_name: [:0]const u8, frame: objc.CGRect) objc.id {
    const cls = objc.getClass(class_name) orelse return null;
    return objc.autorelease(objc.msgSendWith1(objc.CGRect, objc.alloc(cls), "initWithFrame:", frame));
}

fn makeLabel(value: objc.id, color: @TypeOf(theme.text_primary)) objc.id {
    const NSTextField = objc.getClass("NSTextField") orelse return null;
    const label = objc.msgSendWith1(objc.id, @as(objc.id, @ptrCast(NSTextField)), "labelWithString:", value);
    objc.msgSendVoidWith1(objc.id, label, "setTextColor:", window.makeNSColor(color));
    return label;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub fn refreshAll() void {
    const s = state orelse return;
    updatePathField();
    if (s.sidebar_view) |sv| objc.msgSendVoid(sv, "reloadData");
    runQuery(s);
}

/// Show a status hint over the (empty) file list when no index is loaded — the
/// list is index-backed, so an absent index means there is nothing to browse.
pub fn updateEmptyState(s: *AppState) void {
    const label = s.empty_label orelse return;
    const show = s.app.getIndexStatus() == .not_found;
    objc.msgSendVoidWith1(bool, label, "setHidden:", !show);
}

pub fn updatePathField() void {
    const s = state orelse return;
    if (s.path_field) |field| {
        const path = s.app.currentPath();
        const nsstr = objc.NSString.fromSlice(path);
        objc.msgSendVoidWith1(objc.id, field, "setStringValue:", nsstr);
    }
}

fn clickedTableIndex(table_view: objc.id) ?usize {
    const clicked = objc.msgSendI64(table_view, "clickedRow");
    if (clicked >= 0) return @intCast(clicked);
    return null;
}

fn preferredTableIndex(table_view: objc.id) ?usize {
    if (clickedTableIndex(table_view)) |idx| return idx;
    const selected = objc.msgSendI64(table_view, "selectedRow");
    if (selected >= 0) return @intCast(selected);

    return null;
}

fn clickedSidebarIndex(table_view: objc.id) ?usize {
    const clicked = objc.msgSendI64(table_view, "clickedRow");
    if (clicked >= 0) return @intCast(clicked);
    return null;
}

fn preferredSidebarIndex(table_view: objc.id) ?usize {
    if (clickedSidebarIndex(table_view)) |idx| return idx;
    const selected = objc.msgSendI64(table_view, "selectedRow");
    if (selected >= 0) return @intCast(selected);
    return null;
}

fn getPathForRow(s: *AppState, idx: usize) ?[]const u8 {
    const rows = s.rows orelse return null;
    if (idx >= rows.len) return null;
    const r = rows[idx];
    return std.fmt.allocPrint(s.allocator, "{s}/{s}", .{ r.dir_path, r.name }) catch null;
}

fn contextPathFromSenderOrSelection(s: *AppState, sender: objc.id) ?[]const u8 {
    if (representedPathFromSender(s, sender)) |path| return path;

    if (s.table_view) |tv| {
        if (preferredTableIndex(tv)) |idx| {
            return getPathForRow(s, idx);
        }
    }

    if (s.sidebar_view) |sv| {
        if (preferredSidebarIndex(sv)) |idx| {
            return pathForSidebarIndex(s, idx);
        }
    }

    return null;
}

fn representedPathFromSender(s: *AppState, sender: objc.id) ?[]const u8 {
    if (sender == null) return null;
    const represented = objc.msgSend(sender, "representedObject");
    if (represented == null) return null;
    return objc.NSString.toSlice(s.allocator, represented) catch null;
}

fn pathForSidebarIndex(s: *AppState, idx: usize) ?[]const u8 {
    const pins = s.app.getPins();
    if (idx >= pins.len) return null;
    return s.allocator.dupe(u8, pins[idx].path) catch null;
}

fn openPath(s: *AppState, path: []const u8) void {
    if (s.app.fs.isDir(path)) {
        s.app.openDirectory(path) catch return;
        navigateRefresh(s);
        return;
    }
    s.app.openFile(path) catch {};
}

/// True if a double-click at the current event location lands on a data row
/// rather than the column header (or empty area).
fn doubleClickHitDataRow(table_view: objc.id) bool {
    const NSApp = objc.msgSend(objc.getClass("NSApplication") orelse return true, "sharedApplication");
    const event = objc.msgSend(NSApp, "currentEvent");
    if (event == null) return true; // Can't tell — don't block opening.

    const loc_in_window = objc.msgSendFn(*const fn (objc.id, objc.SEL) callconv(.c) objc.CGPoint)(event, objc.sel("locationInWindow"));
    const loc_in_table = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGPoint, objc.id) callconv(.c) objc.CGPoint)(table_view, objc.sel("convertPoint:fromView:"), loc_in_window, null);
    const row = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGPoint) callconv(.c) i64)(table_view, objc.sel("rowAtPoint:"), loc_in_table);
    return row >= 0;
}

fn writePathToPasteboard(path: []const u8) void {
    const pb = objc.msgSend(objc.getClass("NSPasteboard") orelse return, "generalPasteboard");
    objc.msgSendVoid(pb, "clearContents");
    const nsstr = objc.NSString.fromSlice(path);
    const arr = objc.msgSendWith1(objc.id, objc.getClass("NSArray") orelse return, "arrayWithObject:", nsstr);
    _ = objc.msgSendWith1(objc.id, pb, "writeObjects:", arr);
}

fn focusAndSelectView(window_id: objc.id, view: objc.id) void {
    if (window_id) |win| {
        _ = objc.msgSendBoolWith1(objc.id, win, "makeFirstResponder:", view);
    }
    objc.msgSendVoidWith1(objc.id, view, "selectText:", null);
}

fn resolveEnteredPath(s: *AppState, raw_path: []const u8) ?[]u8 {
    const trimmed = std.mem.trim(u8, raw_path, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (std.mem.eql(u8, trimmed, "~")) {
        return runtime.getEnvVarOwned(s.allocator, "HOME") catch null;
    }

    if (std.mem.startsWith(u8, trimmed, "~/")) {
        const home = runtime.getEnvVarOwned(s.allocator, "HOME") catch return null;
        defer s.allocator.free(home);
        return std.fs.path.resolve(s.allocator, &.{ home, trimmed[2..] }) catch null;
    }

    if (std.fs.path.isAbsolute(trimmed)) {
        return std.fs.path.resolve(s.allocator, &.{trimmed}) catch null;
    }

    return std.fs.path.resolve(s.allocator, &.{ s.app.currentPath(), trimmed }) catch null;
}

const MenuTarget = struct {
    path: []const u8,
    is_dir: bool,
    is_pinned: bool,
    color: ?user_state_mod.FolderColor,
};

fn contextTargetForFileMenu(s: *AppState) ?MenuTarget {
    const tv = s.table_view orelse return null;
    const idx = preferredTableIndex(tv) orelse return null;
    const path = getPathForRow(s, idx) orelse return null;
    errdefer s.allocator.free(path);
    const is_dir = s.app.fs.isDir(path);
    return .{
        .path = path,
        .is_dir = is_dir,
        .is_pinned = if (is_dir) isPinnedPath(s, path) else false,
        .color = if (is_dir) s.app.getFolderColor(path) else null,
    };
}

fn contextTargetForSidebarMenu(s: *AppState) ?MenuTarget {
    const sv = s.sidebar_view orelse return null;
    const idx = preferredSidebarIndex(sv) orelse return null;
    const path = pathForSidebarIndex(s, idx) orelse return null;
    errdefer s.allocator.free(path);
    return .{
        .path = path,
        .is_dir = true,
        .is_pinned = true,
        .color = s.app.getFolderColor(path),
    };
}

fn isPinnedPath(s: *AppState, path: []const u8) bool {
    for (s.app.getPins()) |pin| {
        if (std.mem.eql(u8, pin.path, path)) return true;
    }
    return false;
}

fn rebuildFileContextMenu(s: *AppState, menu: objc.id) void {
    const target = contextTargetForFileMenu(s) orelse return;
    defer s.allocator.free(target.path);
    const app_delegate = appDelegate() orelse return;

    addContextItem(menu, "Open", "openItem:", app_delegate, target.path, null, false);
    // Offer "Go to Containing Folder" for a row living below the current scope
    // (a recursive-filter result), so the user can jump to its real directory.
    if (s.table_view) |tv| {
        if (preferredTableIndex(tv)) |idx| {
            if (s.rows) |rows| {
                if (idx < rows.len and !std.mem.eql(u8, rows[idx].dir_path, s.app.navigator.current)) {
                    addContextItem(menu, "Go to Containing Folder", "goToContainingFolder:", app_delegate, rows[idx].dir_path, null, false);
                }
            }
        }
    }
    if (target.is_dir) {
        addContextItem(menu, "Open in Terminal", "openInTerminal:", app_delegate, target.path, null, false);
    }
    addContextItem(menu, "Copy Path", "copyPath:", app_delegate, target.path, null, false);

    if (target.is_dir) {
        addSeparator(menu);
        if (target.is_pinned) {
            addContextItem(menu, "Unpin Folder", "unpinFolder:", app_delegate, target.path, null, false);
        } else {
            addContextItem(menu, "Pin Folder", "pinFolder:", app_delegate, target.path, null, false);
        }
        addFolderColorSubmenu(menu, target.path, target.color, app_delegate);
    }
}

fn rebuildSidebarContextMenu(s: *AppState, menu: objc.id) void {
    const target = contextTargetForSidebarMenu(s) orelse return;
    defer s.allocator.free(target.path);
    const app_delegate = appDelegate() orelse return;

    addContextItem(menu, "Open", "openItem:", app_delegate, target.path, null, false);
    addContextItem(menu, "Copy Path", "copyPath:", app_delegate, target.path, null, false);
    addSeparator(menu);
    addContextItem(menu, "Unpin Folder", "unpinFolder:", app_delegate, target.path, null, false);
    addFolderColorSubmenu(menu, target.path, target.color, app_delegate);
}

fn clearMenu(menu: objc.id) void {
    objc.msgSendVoid(menu, "removeAllItems");
}

fn addContextItem(menu: objc.id, title: []const u8, action: [:0]const u8, target: objc.id, path: []const u8, tag: ?i64, checked: bool) void {
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const item = objc.msgSendWith3(
        objc.id,
        objc.SEL,
        objc.id,
        objc.alloc(NSMenuItem),
        "initWithTitle:action:keyEquivalent:",
        objc.NSString.fromSlice(title),
        objc.sel(action),
        objc.NSString.fromSlice(""),
    );
    objc.msgSendVoidWith1(objc.id, item, "setTarget:", target);
    objc.msgSendVoidWith1(objc.id, item, "setRepresentedObject:", objc.NSString.fromSlice(path));
    if (tag) |tag_value| {
        objc.msgSendVoidWith1(i64, item, "setTag:", tag_value);
    }
    if (checked) {
        objc.msgSendVoidWith1(i64, item, "setState:", @as(i64, 1));
    }
    objc.msgSendVoidWith1(objc.id, menu, "addItem:", item);
}

fn addSeparator(menu: objc.id) void {
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const separator = objc.msgSend(@as(objc.id, @ptrCast(NSMenuItem)), "separatorItem");
    objc.msgSendVoidWith1(objc.id, menu, "addItem:", separator);
}

fn addFolderColorSubmenu(menu: objc.id, path: []const u8, current_color: ?user_state_mod.FolderColor, app_delegate: objc.id) void {
    const NSMenu = objc.getClass("NSMenu") orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const parent = objc.msgSendWith3(
        objc.id,
        objc.SEL,
        objc.id,
        objc.alloc(NSMenuItem),
        "initWithTitle:action:keyEquivalent:",
        objc.NSString.fromSlice("Folder Color"),
        null,
        objc.NSString.fromSlice(""),
    );
    const submenu = objc.init(objc.alloc(NSMenu));

    addContextItem(submenu, "Default", "setFolderColor:", app_delegate, path, 0, current_color == null);
    for (folder_color_presets) |preset| {
        const checked = if (current_color) |color| folderColorEqual(color, preset.color) else false;
        addContextItem(submenu, preset.title, "setFolderColor:", app_delegate, path, preset.tag, checked);
    }

    objc.msgSendVoidWith1(objc.id, parent, "setSubmenu:", submenu);
    objc.msgSendVoidWith1(objc.id, menu, "addItem:", parent);
}

fn appDelegate() objc.id {
    const NSApp = objc.msgSend(objc.getClass("NSApplication") orelse return null, "sharedApplication");
    return objc.msgSend(NSApp, "delegate");
}

fn folderColorForTag(tag: i64) ?user_state_mod.FolderColor {
    for (folder_color_presets) |preset| {
        if (preset.tag == tag) return preset.color;
    }
    return null;
}

fn folderColorEqual(a: user_state_mod.FolderColor, b: user_state_mod.FolderColor) bool {
    return a.red == b.red and a.green == b.green and a.blue == b.blue and a.alpha == b.alpha;
}

fn updateFilterBar(s: *AppState) void {
    const bar = s.filter_bar orelse return;
    const active = s.active_filters;
    const has_filters = if (active) |a| a.len > 0 else false;

    if (!has_filters) {
        window.setFilterBarVisible(bar, s.split_view, false);
        return;
    }

    // Show filter bar with quick filter buttons + pills
    window.setFilterBarVisible(bar, s.split_view, true);
    rebuildFilterBarContent(s, bar, active);
}

fn rebuildFilterBarContent(s: *AppState, bar: objc.id, active: ?[]const filters_mod.FilterCriterion) void {
    // Remove all subviews
    const subviews = objc.msgSend(bar, "subviews");
    if (subviews != null) {
        const count = objc.msgSendI64(subviews, "count");
        var i: i64 = count - 1;
        while (i >= 0) : (i -= 1) {
            const sub = objc.msgSendWith1(i64, subviews, "objectAtIndex:", i);
            objc.msgSendVoid(sub, "removeFromSuperview");
        }
    }

    const app_delegate = appDelegate() orelse return;
    const btn_height: f64 = 22.0;
    const btn_y: f64 = (theme.filter_bar_height - btn_height) / 2.0;
    var x: f64 = 8.0;

    // Quick filter dropdown buttons
    const QuickItem = struct { label: []const u8, value: []const u8 };
    const QuickFilter = struct { title: []const u8, items: []const QuickItem };

    const kind_items = [_]QuickItem{
        .{ .label = "File", .value = "kind:file" },
        .{ .label = "Folder", .value = "kind:folder" },
        .{ .label = "Symlink", .value = "kind:symlink" },
    };
    const ext_items = [_]QuickItem{
        .{ .label = "pdf", .value = "ext:pdf" },
        .{ .label = "txt", .value = "ext:txt" },
        .{ .label = "jpg", .value = "ext:jpg" },
        .{ .label = "png", .value = "ext:png" },
        .{ .label = "zip", .value = "ext:zip" },
        .{ .label = "mp3", .value = "ext:mp3" },
        .{ .label = "mp4", .value = "ext:mp4" },
        .{ .label = "py", .value = "ext:py" },
        .{ .label = "js", .value = "ext:js" },
        .{ .label = "zig", .value = "ext:zig" },
    };
    const size_items = [_]QuickItem{
        .{ .label = "> 1 MB", .value = "size:>1mb" },
        .{ .label = "> 10 MB", .value = "size:>10mb" },
        .{ .label = "> 100 MB", .value = "size:>100mb" },
        .{ .label = "< 1 KB", .value = "size:<1kb" },
        .{ .label = "1-10 MB", .value = "size:1mb..10mb" },
    };
    const date_items = [_]QuickItem{
        .{ .label = "Today", .value = "date:today" },
        .{ .label = "This Week", .value = "date:week" },
        .{ .label = "This Month", .value = "date:month" },
        .{ .label = "This Year", .value = "date:year" },
    };
    const cat_items = [_]QuickItem{
        .{ .label = "Images", .value = "cat:images" },
        .{ .label = "Text", .value = "cat:text" },
        .{ .label = "Documents", .value = "cat:documents" },
        .{ .label = "Code", .value = "cat:code" },
        .{ .label = "Audio", .value = "cat:audio" },
        .{ .label = "Video", .value = "cat:video" },
        .{ .label = "Archives", .value = "cat:archives" },
    };

    const quick_filters = [_]QuickFilter{
        .{ .title = "Kind", .items = &kind_items },
        .{ .title = "Ext", .items = &ext_items },
        .{ .title = "Size", .items = &size_items },
        .{ .title = "Date", .items = &date_items },
        .{ .title = "Category", .items = &cat_items },
    };

    const NSPopUpButton = objc.getClass("NSPopUpButton") orelse return;

    for (quick_filters) |qf| {
        const btn_width = @as(f64, @floatFromInt(qf.title.len)) * 8.0 + 28.0;
        const popup = objc.msgSendWith2(
            objc.CGRect,
            bool,
            objc.alloc(NSPopUpButton),
            "initWithFrame:pullsDown:",
            objc.CGRect.make(x, btn_y, btn_width, btn_height),
            true,
        );
        if (popup == null) continue;

        // Title item (displayed on button)
        objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice(qf.title));
        // Menu items
        for (qf.items) |item| {
            objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice(item.label));
        }
        // Set represented objects + action on menu items
        if (objc.msgSend(popup, "menu")) |menu| {
            for (qf.items, 0..) |item, i| {
                const mi = objc.msgSendWith1(i64, menu, "itemAtIndex:", @as(i64, @intCast(i + 1)));
                objc.msgSendVoidWith1(objc.id, mi, "setRepresentedObject:", objc.NSString.fromSlice(item.value));
                objc.msgSendVoidWith1(objc.id, mi, "setTarget:", app_delegate);
                objc.msgSendVoidWith1(objc.SEL, mi, "setAction:", objc.sel("quickFilterSelected:"));
            }
        }
        // Small control size
        objc.msgSendVoidWith1(i64, popup, "setControlSize:", @as(i64, 1)); // NSControlSizeSmall
        if (objc.msgSend(popup, "cell")) |cell| {
            objc.msgSendVoidWith1(i64, cell, "setControlSize:", @as(i64, 1));
        }
        objc.msgSendVoidWith1(objc.id, bar, "addSubview:", popup);
        x += btn_width + theme.quick_filter_gap;
    }

    // "Saved" quick filter popup (dynamically populated)
    {
        const btn_width: f64 = 72.0;
        const popup = objc.msgSendWith2(
            objc.CGRect,
            bool,
            objc.alloc(NSPopUpButton),
            "initWithFrame:pullsDown:",
            objc.CGRect.make(x, btn_y, btn_width, btn_height),
            true,
        );
        if (popup != null) {
            objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice("Saved"));
            const saved = s.app.user_state.getSavedFilters();
            if (saved.len == 0) {
                objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice("(none)"));
                if (objc.msgSend(popup, "menu")) |menu| {
                    const mi = objc.msgSendWith1(i64, menu, "itemAtIndex:", @as(i64, 1));
                    objc.msgSendVoidWith1(bool, mi, "setEnabled:", false);
                }
            } else {
                for (saved) |sf| {
                    objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice(sf.name));
                }
                if (objc.msgSend(popup, "menu")) |menu| {
                    for (saved, 0..) |sf, i| {
                        const mi = objc.msgSendWith1(i64, menu, "itemAtIndex:", @as(i64, @intCast(i + 1)));
                        objc.msgSendVoidWith1(objc.id, mi, "setRepresentedObject:", objc.NSString.fromSlice(sf.query));
                        objc.msgSendVoidWith1(objc.id, mi, "setTarget:", app_delegate);
                        objc.msgSendVoidWith1(objc.SEL, mi, "setAction:", objc.sel("loadSavedFilter:"));
                    }
                }
            }
            objc.msgSendVoidWith1(i64, popup, "setControlSize:", @as(i64, 1));
            if (objc.msgSend(popup, "cell")) |cell| {
                objc.msgSendVoidWith1(i64, cell, "setControlSize:", @as(i64, 1));
            }
            objc.msgSendVoidWith1(objc.id, bar, "addSubview:", popup);
            x += btn_width + theme.quick_filter_gap;
        }
    }

    // Separator between quick filters and pills
    if (active) |filters| {
        if (filters.len > 0) {
            x += 8.0;

            // Active filter pills
            for (filters, 0..) |criterion, idx| {
                var buf: [128]u8 = undefined;
                const label_text = filters_mod.formatCriterion(criterion, &buf);
                if (label_text.len == 0) continue;

                const pill_width = @as(f64, @floatFromInt(label_text.len)) * 7.5 + 30.0;
                const pill = window.makePillView(
                    objc.CGRect.make(x, btn_y, pill_width, btn_height),
                    label_text,
                    @intCast(idx),
                    app_delegate,
                );
                if (pill != null) {
                    objc.msgSendVoidWith1(objc.id, bar, "addSubview:", pill);
                }
                x += pill_width + 6.0;
            }

            // Save button on the right side
            const save_btn = window.makeButton("Save", "saveFilter:", app_delegate);
            if (save_btn != null) {
                const bar_frame = window.getFrame(bar);
                window.msgSendRect(save_btn, "setFrame:", objc.CGRect.make(bar_frame.size.width - 70, btn_y, 60, btn_height));
                objc.msgSendVoidWith1(i64, save_btn, "setBezelStyle:", @as(i64, 10));
                objc.msgSendVoidWith1(objc.id, bar, "addSubview:", save_btn);
            }
        }
    }
}

fn formatSize(size: u64, buf: []u8) []const u8 {
    if (size == 0) return "0 B";
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(size);
    var unit_idx: usize = 0;
    while (value >= 1024.0 and unit_idx < units.len - 1) {
        value /= 1024.0;
        unit_idx += 1;
    }
    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d} B", .{size}) catch "--";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit_idx] }) catch "--";
    }
}

fn formatDate(mtime: i64, buf: []u8) []const u8 {
    if (mtime <= 0) return "--";

    var raw: c.time_t = @intCast(mtime);
    var tm_value: c.struct_tm = undefined;
    if (c.localtime_r(&raw, &tm_value) == null) return "--";

    const written = c.strftime(buf.ptr, buf.len, "%b %e", &tm_value);
    if (written == 0) return "--";
    return buf[0..written];
}
