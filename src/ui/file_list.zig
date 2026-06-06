const objc = @import("objc.zig");
const theme = @import("theme.zig");
const delegate = @import("delegate.zig");
const window = @import("window.zig");

const NSViewWidthSizable: u64 = 2;
const NSViewMinYMargin: u64 = 8;
const NSViewHeightSizable: u64 = 16;
const NSViewMaxYMargin: u64 = 32;

fn setAutoresizingMask(view: objc.id, mask: u64) void {
    objc.msgSendVoidWith1(u64, view, "setAutoresizingMask:", mask);
}

pub fn createFileList(s: *delegate.AppState, frame: objc.CGRect) objc.id {
    const NSScrollView = objc.getClass("NSScrollView") orelse return null;
    // ZestTableView (NSTableView subclass) adds Return/Enter-to-open.
    const NSTableView = objc.getClass("ZestTableView") orelse objc.getClass("NSTableView") orelse return null;
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
    const NSSortDescriptor = objc.getClass("NSSortDescriptor");
    for (col_specs) |spec| {
        const col = objc.msgSendWith1(objc.id, objc.alloc(NSTableColumn), "initWithIdentifier:", objc.NSString.fromSlice(spec.id));
        const header = objc.msgSend(col, "headerCell");
        objc.msgSendVoidWith1(objc.id, header, "setStringValue:", objc.NSString.fromSlice(spec.title));
        setWidth(col, objc.sel("setWidth:"), spec.width);
        // Make the column sortable: clicking its header sends
        // tableView:sortDescriptorsDidChange: keyed by the column identifier.
        if (NSSortDescriptor) |cls| {
            const proto = objc.autorelease(objc.msgSendWith2(objc.id, bool, objc.alloc(cls), "initWithKey:ascending:", objc.NSString.fromSlice(spec.id), true));
            objc.msgSendVoidWith1(objc.id, col, "setSortDescriptorPrototype:", proto);
        }
        objc.msgSendVoidWith1(objc.id, table, "addTableColumn:", col);
    }

    // Default sort indicator: Name ascending (matches AppState.sort default).
    if (NSSortDescriptor) |cls| {
        const name_desc = objc.autorelease(objc.msgSendWith2(objc.id, bool, objc.alloc(cls), "initWithKey:ascending:", objc.NSString.fromSlice("name"), true));
        if (objc.getClass("NSArray")) |NSArray| {
            const arr = objc.msgSendWith1(objc.id, @as(objc.id, @ptrCast(NSArray)), "arrayWithObject:", name_desc);
            objc.msgSendVoidWith1(objc.id, table, "setSortDescriptors:", arr);
        }
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

    // Empty-state hint, shown over the list when no index is loaded.
    if (objc.getClass("NSTextField")) |NSTextField| {
        const label = objc.msgSendWith1(objc.id, @as(objc.id, @ptrCast(NSTextField)), "labelWithString:", objc.NSString.fromSlice("No index — run zest-indexer"));
        objc.msgSendVoidWith1(objc.id, label, "setTextColor:", window.makeNSColor(theme.text_secondary));
        objc.msgSendVoidWith1(i64, label, "setAlignment:", @as(i64, 1)); // center
        window.msgSendRect(label, "setFrame:", objc.CGRect.make(20, frame.size.height / 2 - 10, frame.size.width - 40, 20));
        setAutoresizingMask(label, NSViewWidthSizable | NSViewMinYMargin | NSViewMaxYMargin);
        objc.msgSendVoidWith1(bool, label, "setHidden:", true);
        objc.msgSendVoidWith1(objc.id, scroll, "addSubview:", label);
        s.empty_label = label;
    }

    // Context menu
    buildContextMenu(s, table, app_delegate);

    return scroll;
}

fn buildContextMenu(s: *delegate.AppState, table: objc.id, app_delegate: objc.id) void {
    const NSMenu = objc.getClass("NSMenu") orelse return;
    const menu = objc.init(objc.alloc(NSMenu));
    objc.msgSendVoidWith1(objc.id, menu, "setDelegate:", app_delegate);
    objc.msgSendVoidWith1(objc.id, table, "setMenu:", menu);
    s.file_context_menu = menu;
}
