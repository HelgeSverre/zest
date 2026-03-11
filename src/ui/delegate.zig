const std = @import("std");
const objc = @import("objc.zig");
const types = @import("../core/types.zig");
const App = @import("../app.zig").App;
const search_mod = @import("../index/search.zig");
const window = @import("window.zig");
const theme = @import("theme.zig");
const file_list = @import("file_list.zig");

const c = @cImport({
    @cInclude("time.h");
});

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
        _ = objc.addMethod(cls, "tableView:viewForTableColumn:row:", tableViewForColumn, "@@:@@q");
        objc.registerClassPair(cls);
    }

    // ZestSidebarDataSource
    {
        const cls = objc.allocateClassPair(NSObject, "ZestSidebarDataSource") orelse @panic("Failed to create ZestSidebarDataSource");
        _ = objc.addMethod(cls, "numberOfRowsInTableView:", sidebarNumberOfRows, "q@:@");
        _ = objc.addMethod(cls, "tableView:objectValueForTableColumn:row:", sidebarObjectValue, "@@:@@q");
        _ = objc.addMethod(cls, "tableView:viewForTableColumn:row:", sidebarViewForColumn, "@@:@@q");
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
    const idx = preferredTableIndex(tv) orelse return;

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
            category = std.meta.intToEnum(types.FileCategory, @as(u8, @intCast(idx))) catch null;
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
    const idx = clickedTableIndex(tv) orelse return;
    const path = getPathForRow(s, idx) orelse return;
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
    const idx = clickedTableIndex(tv) orelse return;
    const path = getPathForRow(s, idx) orelse return;
    defer s.allocator.free(path);
    s.app.openInTerminal(path) catch {};
}

fn pinFolderAction(_self: objc.id, _cmd: objc.SEL, _sender: objc.id) callconv(.c) void {
    _ = _self;
    _ = _cmd;
    _ = _sender;
    const s = state orelse return;
    const tv = s.table_view orelse return;
    const idx = clickedTableIndex(tv) orelse return;

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
        return objc.NSString.fromSlice(entry.name);
    } else if (std.mem.eql(u8, col_id, "size")) {
        if (entry.isDirectory()) return objc.NSString.fromSlice("--");
        var buf: [32]u8 = undefined;
        const size_str = formatSize(entry.size, &buf);
        return objc.NSString.fromSlice(size_str);
    } else if (std.mem.eql(u8, col_id, "modified")) {
        var buf: [32]u8 = undefined;
        return objc.NSString.fromSlice(formatDate(entry.mtime, &buf));
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
        return objc.NSString.fromSlice(result.name);
    } else if (std.mem.eql(u8, col_id, "size")) {
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
        if (s.is_search_mode) {
            const results = s.search_results orelse return null;
            if (idx >= results.len) return null;
            const result = results[idx];
            const path = std.fmt.allocPrint(s.allocator, "{s}/{s}", .{ result.dir_path, result.name }) catch return null;
            defer s.allocator.free(path);
            return buildNameCell(table, column, "NameCell", result.name, path, theme.file_row_height, theme.text_bright);
        }

        const listing = s.current_entries orelse return null;
        if (idx >= listing.entries.len) return null;
        const entry = listing.entries[idx];
        return buildNameCell(table, column, "NameCell", entry.name, entry.path, theme.file_row_height, theme.text_bright);
    }

    const value = if (s.is_search_mode)
        tableObjectValueSearch(s, col_id, idx)
    else
        tableObjectValueDir(s, col_id, idx);
    if (value == null) return null;

    const color = if (std.mem.eql(u8, col_id, "type"))
        theme.text_primary
    else
        theme.text_secondary;
    const alignment: i64 = if (std.mem.eql(u8, col_id, "size")) 2 else 0;
    return buildTextCell(table, column, "ValueCell", value, color, alignment, theme.file_row_height);
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
    return buildNameCell(table, column, "SidebarCell", pin.name, pin.path, theme.sidebar_row_height, theme.text_primary);
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
    objc.msgSendVoidWith1(objc.CGRect, label, "setFrame:", objc.CGRect.make(10, 6, label_width, height - 12));
    objc.msgSendVoidWith1(i64, label, "setAlignment:", alignment);
    objc.msgSendVoidWith1(bool, label, "setUsesSingleLineMode:", true);
    objc.msgSendVoidWith1(i64, label, "setLineBreakMode:", @as(i64, 4));
    return cell;
}

fn buildNameCell(table: objc.id, column: objc.id, identifier_text: []const u8, title: []const u8, full_path: []const u8, height: f64, color: @TypeOf(theme.text_primary)) objc.id {
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
        const icon = iconForPath(full_path);
        if (icon != null) {
            objc.msgSendVoidWith1(objc.id, iv, "setImage:", icon);
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

fn iconForPath(path: []const u8) objc.id {
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return null;
    const workspace = objc.msgSend(@as(objc.id, @ptrCast(NSWorkspace)), "sharedWorkspace");
    return objc.msgSendWith1(objc.id, workspace, "iconForFile:", objc.NSString.fromSlice(path));
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

fn formatDate(mtime: i64, buf: []u8) []const u8 {
    if (mtime <= 0) return "--";

    var raw: c.time_t = @intCast(mtime);
    var tm_value: c.struct_tm = undefined;
    if (c.localtime_r(&raw, &tm_value) == null) return "--";

    const written = c.strftime(buf.ptr, buf.len, "%b %e", &tm_value);
    if (written == 0) return "--";
    return buf[0..written];
}
