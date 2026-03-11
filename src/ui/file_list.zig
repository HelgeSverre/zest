const std = @import("std");
const objc = @import("objc.zig");
const theme = @import("theme.zig");
const delegate = @import("delegate.zig");
const window = @import("window.zig");
const types = @import("../core/types.zig");

const NSViewWidthSizable: u64 = 2;
const NSViewHeightSizable: u64 = 16;

fn setAutoresizingMask(view: objc.id, mask: u64) void {
    objc.msgSendVoidWith1(u64, view, "setAutoresizingMask:", mask);
}

pub fn createFileList(s: *delegate.AppState, frame: objc.CGRect) objc.id {
    const NSScrollView = objc.getClass("NSScrollView") orelse return null;
    const NSTableView = objc.getClass("NSTableView") orelse return null;
    const NSTableColumn = objc.getClass("NSTableColumn") orelse return null;

    const table = objc.autorelease(objc.msgSendWith1(objc.CGRect, objc.alloc(NSTableView), "initWithFrame:", objc.CGRect.make(0, 0, frame.size.width, frame.size.height)));
    s.table_view = table;
    setAutoresizingMask(table, NSViewWidthSizable | NSViewHeightSizable);

    // Add columns
    const col_specs = [_]struct { id: []const u8, title: []const u8, width: f64 }{
        .{ .id = "name", .title = "Name", .width = 420 },
        .{ .id = "size", .title = "Size", .width = 80 },
        .{ .id = "modified", .title = "Modified", .width = 140 },
        .{ .id = "type", .title = "Type", .width = 100 },
    };

    const setWidth = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGFloat) callconv(.c) void);
    for (col_specs) |spec| {
        const col = objc.msgSendWith1(objc.id, objc.alloc(NSTableColumn), "initWithIdentifier:", objc.NSString.fromSlice(spec.id));
        const header = objc.msgSend(col, "headerCell");
        objc.msgSendVoidWith1(objc.id, header, "setStringValue:", objc.NSString.fromSlice(spec.title));
        setWidth(col, objc.sel("setWidth:"), spec.width);
        objc.msgSendVoidWith1(objc.id, table, "addTableColumn:", col);
    }

    // Data source/delegate — alloc/init gives +1 retain count, intentionally kept alive
    // for the app's lifetime (NSTableView holds weak refs to data source/delegate)
    const data_source_cls = objc.getClass("ZestTableDataSource") orelse return null;
    const data_source = objc.init(objc.alloc(data_source_cls));
    objc.msgSendVoidWith1(objc.id, table, "setDataSource:", data_source);
    objc.msgSendVoidWith1(objc.id, table, "setDelegate:", data_source);

    // Appearance
    objc.msgSendVoidWith1(objc.id, table, "setBackgroundColor:", window.makeNSColor(theme.background));
    const setRowHeight = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGFloat) callconv(.c) void);
    setRowHeight(table, objc.sel("setRowHeight:"), theme.file_row_height);
    objc.msgSendVoidWith1(bool, table, "setAllowsEmptySelection:", false);
    objc.msgSendVoidWith1(bool, table, "setUsesAlternatingRowBackgroundColors:", false);

    // Double-click action
    const NSApp = objc.msgSend(objc.getClass("NSApplication").?, "sharedApplication");
    const app_delegate = objc.msgSend(NSApp, "delegate");
    objc.msgSendVoidWith1(objc.id, table, "setTarget:", app_delegate);
    objc.msgSendVoidWith1(objc.SEL, table, "setDoubleAction:", objc.sel("openItem:"));

    // Column auto-resizing
    objc.msgSendVoidWith1(u64, table, "setColumnAutoresizingStyle:", 4);

    // Wrap in scroll view
    const scroll = objc.autorelease(objc.msgSendWith1(objc.CGRect, objc.alloc(NSScrollView), "initWithFrame:", frame));
    setAutoresizingMask(scroll, NSViewWidthSizable | NSViewHeightSizable);
    objc.msgSendVoidWith1(objc.id, scroll, "setDocumentView:", table);
    objc.msgSendVoidWith1(bool, scroll, "setHasVerticalScroller:", true);
    objc.msgSendVoidWith1(bool, scroll, "setAutohidesScrollers:", true);

    // Context menu
    buildContextMenu(table, app_delegate);

    return scroll;
}

pub fn refreshFileList() void {
    const s = delegate.state orelse return;
    if (s.is_search_mode) {
        if (s.table_view) |tv| objc.msgSendVoid(tv, "reloadData");
        return;
    }

    if (s.current_entries) |*listing| {
        listing.deinit();
        s.current_entries = null;
    }

    const listing = s.app.getCurrentEntries() catch return;

    std.mem.sort(types.FileEntry, listing.entries, {}, struct {
        fn lessThan(_: void, a: types.FileEntry, b: types.FileEntry) bool {
            if (a.isDirectory() != b.isDirectory()) return a.isDirectory();
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lessThan);

    s.current_entries = listing;
    if (s.table_view) |tv| objc.msgSendVoid(tv, "reloadData");
}

fn buildContextMenu(table: objc.id, app_delegate: objc.id) void {
    const NSMenu = objc.getClass("NSMenu") orelse return;
    const menu = objc.init(objc.alloc(NSMenu));

    addContextItem(menu, "Open", "openItem:", app_delegate);
    addContextItem(menu, "Open in Terminal", "openInTerminal:", app_delegate);

    if (objc.getClass("NSMenuItem")) |NSMenuItem| {
        const sep = objc.msgSend(@as(objc.id, @ptrCast(NSMenuItem)), "separatorItem");
        objc.msgSendVoidWith1(objc.id, menu, "addItem:", sep);
    }

    addContextItem(menu, "Pin Folder", "pinFolder:", app_delegate);
    addContextItem(menu, "Copy Path", "copyPath:", app_delegate);

    objc.msgSendVoidWith1(objc.id, table, "setMenu:", menu);
}

fn addContextItem(menu: objc.id, title: []const u8, action: [:0]const u8, target: objc.id) void {
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
    objc.msgSendVoidWith1(objc.id, menu, "addItem:", item);
}
