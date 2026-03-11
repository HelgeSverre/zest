const std = @import("std");
const objc = @import("objc.zig");
const types = @import("../core/types.zig");
const App = @import("../app.zig").App;
const search_mod = @import("../index/search.zig");
const window = @import("window.zig");
const file_list = @import("file_list.zig");
const sidebar = @import("sidebar.zig");

// ---------------------------------------------------------------------------
// Global application state (single-window app)
// ---------------------------------------------------------------------------

pub const AppState = struct {
    app: *App,
    allocator: std.mem.Allocator,
    // UI references
    window_id: objc.id = null,
    table_view: objc.id = null,
    sidebar_view: objc.id = null,
    search_field: objc.id = null,
    path_label: objc.id = null,
    category_popup: objc.id = null,
    // Display data
    current_entries: ?types.DirListing = null,
    search_results: ?[]search_mod.SearchResult = null,
    is_search_mode: bool = false,

    pub fn deinit(self: *AppState) void {
        if (self.current_entries) |*listing| listing.deinit();
        if (self.search_results) |results| self.allocator.free(results);
    }
};

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
        _ = objc.addMethod(cls, "searchAction:", searchAction, "v@:@");
        _ = objc.addMethod(cls, "categoryChanged:", categoryChangedAction, "v@:@");
        _ = objc.addMethod(cls, "pollIndex:", pollIndexAction, "v@:@");
        _ = objc.addMethod(cls, "copyPath:", copyPathAction, "v@:@");
        _ = objc.addMethod(cls, "openInTerminal:", openInTerminalAction, "v@:@");
        _ = objc.addMethod(cls, "pinFolder:", pinFolderAction, "v@:@");
        objc.registerClassPair(cls);
    }

    // ZestTableDataSource
    {
        const cls = objc.allocateClassPair(NSObject, "ZestTableDataSource") orelse @panic("Failed to create ZestTableDataSource");
        _ = objc.addMethod(cls, "numberOfRowsInTableView:", tableNumberOfRows, "q@:@");
        _ = objc.addMethod(cls, "tableView:objectValueForTableColumn:row:", tableObjectValue, "@@:@@q");
        objc.registerClassPair(cls);
    }

    // ZestSidebarDataSource
    {
        const cls = objc.allocateClassPair(NSObject, "ZestSidebarDataSource") orelse @panic("Failed to create ZestSidebarDataSource");
        _ = objc.addMethod(cls, "numberOfRowsInTableView:", sidebarNumberOfRows, "q@:@");
        _ = objc.addMethod(cls, "tableView:objectValueForTableColumn:row:", sidebarObjectValue, "@@:@@q");
        _ = objc.addMethod(cls, "tableViewSelectionDidChange:", sidebarSelectionChanged, "v@:@");
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
    refreshAll();
}

fn forwardAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    _ = s.app.goForward() catch return;
    refreshAll();
}

fn upAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    _ = s.app.goUp() catch return;
    refreshAll();
}

fn openItemAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    const tv = s.table_view orelse return;
    const row = objc.msgSendI64(tv, "clickedRow");
    if (row < 0) return;
    const idx: usize = @intCast(row);

    if (s.is_search_mode) {
        if (s.search_results) |results| {
            if (idx < results.len) {
                // Build full path from search result
                const result = results[idx];
                const full = std.fmt.allocPrint(s.allocator, "{s}/{s}", .{ result.dir_path, result.name }) catch return;
                defer s.allocator.free(full);
                if (result.kind == .directory) {
                    s.app.openDirectory(full) catch return;
                    s.is_search_mode = false;
                    refreshAll();
                } else {
                    s.app.openFile(full) catch {};
                }
            }
        }
    } else {
        if (s.current_entries) |listing| {
            if (idx < listing.entries.len) {
                const entry = listing.entries[idx];
                if (entry.isDirectory()) {
                    // Build full path
                    const full = std.fmt.allocPrint(s.allocator, "{s}/{s}", .{ s.app.currentPath(), entry.name }) catch return;
                    defer s.allocator.free(full);
                    s.app.openDirectory(full) catch return;
                    refreshAll();
                } else {
                    const full = std.fmt.allocPrint(s.allocator, "{s}/{s}", .{ s.app.currentPath(), entry.name }) catch return;
                    defer s.allocator.free(full);
                    s.app.openFile(full) catch {};
                }
            }
        }
    }
}

fn searchAction(_self: objc.id, _cmd: objc.SEL, sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    runSearch(sender);
}

fn categoryChangedAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    if (!s.is_search_mode) return;
    if (s.search_field) |sf| runSearch(sf);
}

fn runSearch(search_field_obj: objc.id) void {
    const s = state orelse return;

    const nsstr = objc.msgSend(search_field_obj, "stringValue");
    const query = objc.NSString.toSlice(s.allocator, nsstr) catch return;
    defer s.allocator.free(query);

    if (query.len == 0) {
        s.is_search_mode = false;
        if (s.search_results) |results| s.allocator.free(results);
        s.search_results = null;
        file_list.refreshFileList();
        return;
    }

    // Get selected category from popup
    var category: ?types.FileCategory = null;
    if (s.category_popup) |popup| {
        const idx = objc.msgSendI64(popup, "indexOfSelectedItem");
        if (idx > 0) {
            category = std.meta.intToEnum(types.FileCategory, @as(u8, @intCast(idx - 1))) catch null;
        }
    }

    if (s.search_results) |results| s.allocator.free(results);
    s.search_results = s.app.search(query, category) catch null;
    s.is_search_mode = true;

    if (s.table_view) |tv| objc.msgSendVoid(tv, "reloadData");
}

fn pollIndexAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    s.app.checkForIndexUpdate();
}

fn copyPathAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    const tv = s.table_view orelse return;
    const row = objc.msgSendI64(tv, "clickedRow");
    if (row < 0) return;
    const path = getPathForRow(s, @intCast(row)) orelse return;
    defer s.allocator.free(path);

    const pb = objc.msgSend(objc.getClass("NSPasteboard") orelse return, "generalPasteboard");
    objc.msgSendVoid(pb, "clearContents");
    const nsstr = objc.NSString.fromSlice(path);
    const arr = objc.msgSendWith1(objc.id, objc.getClass("NSArray") orelse return, "arrayWithObject:", nsstr);
    _ = objc.msgSendWith1(objc.id, pb, "writeObjects:", arr);
}

fn openInTerminalAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    const tv = s.table_view orelse return;
    const row = objc.msgSendI64(tv, "clickedRow");
    if (row < 0) return;
    const path = getPathForRow(s, @intCast(row)) orelse return;
    defer s.allocator.free(path);
    s.app.openInTerminal(path) catch {};
}

fn pinFolderAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    const tv = s.table_view orelse return;
    const row = objc.msgSendI64(tv, "clickedRow");
    if (row < 0) return;
    const idx: usize = @intCast(row);

    if (s.is_search_mode) {
        if (s.search_results) |results| {
            if (idx < results.len) {
                const r = results[idx];
                if (r.kind == .directory) {
                    const full = std.fmt.allocPrint(s.allocator, "{s}/{s}", .{ r.dir_path, r.name }) catch return;
                    defer s.allocator.free(full);
                    s.app.addPin(r.name, full) catch {};
                    if (s.sidebar_view) |sv| objc.msgSendVoid(sv, "reloadData");
                }
            }
        }
    } else if (s.current_entries) |listing| {
        if (idx < listing.entries.len) {
            const entry = listing.entries[idx];
            if (entry.isDirectory()) {
                const full = std.fmt.allocPrint(s.allocator, "{s}/{s}", .{ s.app.currentPath(), entry.name }) catch return;
                defer s.allocator.free(full);
                s.app.addPin(entry.name, full) catch {};
                if (s.sidebar_view) |sv| objc.msgSendVoid(sv, "reloadData");
            }
        }
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
    if (s.is_search_mode) {
        if (s.search_results) |results| return @intCast(results.len);
        return 0;
    }
    if (s.current_entries) |listing| return @intCast(listing.entries.len);
    return 0;
}

fn tableObjectValue(_self: objc.id, _cmd: objc.SEL, _table: objc.id, column: objc.id, row: i64) callconv(.c) objc.id {
    _ = _self;
    _ = _cmd;
    _ = _table;
    const s = state orelse return null;
    if (row < 0) return null;
    const idx: usize = @intCast(row);

    // Get column identifier
    const col_id_ns = objc.msgSend(column, "identifier");
    const col_id = objc.NSString.toSlice(s.allocator, col_id_ns) catch return null;
    defer s.allocator.free(col_id);

    if (s.is_search_mode) {
        return tableObjectValueSearch(s, col_id, idx);
    } else {
        return tableObjectValueDir(s, col_id, idx);
    }
}

fn tableObjectValueDir(s: *AppState, col_id: []const u8, idx: usize) objc.id {
    const listing = s.current_entries orelse return null;
    if (idx >= listing.entries.len) return null;
    const entry = listing.entries[idx];

    if (std.mem.eql(u8, col_id, "name")) {
        const icon: []const u8 = if (entry.isDirectory()) "\xF0\x9F\x93\x81 " else "\xF0\x9F\x93\x84 "; // folder/page emoji
        const display = std.fmt.allocPrint(s.allocator, "{s}{s}", .{ icon, entry.name }) catch return null;
        defer s.allocator.free(display);
        return objc.NSString.fromSlice(display);
    } else if (std.mem.eql(u8, col_id, "size")) {
        if (entry.isDirectory()) return objc.NSString.fromSlice("--");
        var buf: [32]u8 = undefined;
        const size_str = formatSize(entry.size, &buf);
        return objc.NSString.fromSlice(size_str);
    } else if (std.mem.eql(u8, col_id, "type")) {
        return objc.NSString.fromSlice(entry.category.displayName());
    }
    return null;
}

fn tableObjectValueSearch(s: *AppState, col_id: []const u8, idx: usize) objc.id {
    const results = s.search_results orelse return null;
    if (idx >= results.len) return null;
    const result = results[idx];

    if (std.mem.eql(u8, col_id, "name")) {
        const icon: []const u8 = if (result.kind == .directory) "\xF0\x9F\x93\x81 " else "\xF0\x9F\x93\x84 ";
        const display = std.fmt.allocPrint(s.allocator, "{s}{s}", .{ icon, result.name }) catch return null;
        defer s.allocator.free(display);
        return objc.NSString.fromSlice(display);
    } else if (std.mem.eql(u8, col_id, "size")) {
        if (result.kind == .directory) return objc.NSString.fromSlice("--");
        var buf: [32]u8 = undefined;
        const size_str = formatSize(result.size, &buf);
        return objc.NSString.fromSlice(size_str);
    } else if (std.mem.eql(u8, col_id, "type")) {
        return objc.NSString.fromSlice(result.category.displayName());
    }
    return null;
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
    const display = std.fmt.allocPrint(s.allocator, "\xF0\x9F\x93\x81 {s}", .{pin.name}) catch return null;
    defer s.allocator.free(display);
    return objc.NSString.fromSlice(display);
}

fn sidebarSelectionChanged(_self: objc.id, _cmd: objc.SEL, _notification: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _notification;
    const s = state orelse return;
    const sv = s.sidebar_view orelse return;
    const row = objc.msgSendI64(sv, "selectedRow");
    if (row < 0) return;
    const pins = s.app.getPins();
    const idx: usize = @intCast(row);
    if (idx >= pins.len) return;
    const pin = pins[idx];
    s.app.openDirectory(pin.path) catch return;
    s.is_search_mode = false;
    refreshAll();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub fn refreshAll() void {
    const s = state orelse return;
    file_list.refreshFileList();
    updatePathLabel();
    if (s.sidebar_view) |sv| objc.msgSendVoid(sv, "reloadData");
}

pub fn updatePathLabel() void {
    const s = state orelse return;
    if (s.path_label) |label| {
        const path = s.app.currentPath();
        const nsstr = objc.NSString.fromSlice(path);
        objc.msgSendVoidWith1(objc.id, label, "setStringValue:", nsstr);
    }
}

fn getPathForRow(s: *AppState, idx: usize) ?[]const u8 {
    if (s.is_search_mode) {
        if (s.search_results) |results| {
            if (idx < results.len) {
                const r = results[idx];
                return std.fmt.allocPrint(s.allocator, "{s}/{s}", .{ r.dir_path, r.name }) catch null;
            }
        }
    } else {
        if (s.current_entries) |listing| {
            if (idx < listing.entries.len) {
                const entry = listing.entries[idx];
                return std.fmt.allocPrint(s.allocator, "{s}/{s}", .{ s.app.currentPath(), entry.name }) catch null;
            }
        }
    }
    return null;
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
