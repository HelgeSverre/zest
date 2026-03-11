const objc = @import("objc.zig");
const theme = @import("theme.zig");
const delegate = @import("delegate.zig");
const window = @import("window.zig");

pub fn createSidebar(s: *delegate.AppState) objc.id {
    const NSScrollView = objc.getClass("NSScrollView") orelse return null;
    const NSTableView = objc.getClass("NSTableView") orelse return null;
    const NSTableColumn = objc.getClass("NSTableColumn") orelse return null;

    const table = objc.init(objc.alloc(NSTableView));
    s.sidebar_view = table;

    // Single column, no header
    const col = objc.msgSendWith1(objc.id, objc.alloc(NSTableColumn), "initWithIdentifier:", objc.NSString.fromSlice("pin"));
    const setWidth = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGFloat) callconv(.c) void);
    setWidth(col, objc.sel("setWidth:"), theme.sidebar_width - 20);
    objc.msgSendVoidWith1(objc.id, table, "addTableColumn:", col);

    // Hide header
    objc.msgSendVoidWith1(objc.id, table, "setHeaderView:", null);

    // Data source and delegate
    const ds_cls = objc.getClass("ZestSidebarDataSource") orelse return null;
    const ds = objc.init(objc.alloc(ds_cls));
    objc.msgSendVoidWith1(objc.id, table, "setDataSource:", ds);
    objc.msgSendVoidWith1(objc.id, table, "setDelegate:", ds);

    // Appearance
    objc.msgSendVoidWith1(objc.id, table, "setBackgroundColor:", window.makeNSColor(theme.sidebar));
    const setRowHeight = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGFloat) callconv(.c) void);
    setRowHeight(table, objc.sel("setRowHeight:"), 24.0);

    // Selection highlight
    objc.msgSendVoidWith1(i64, table, "setSelectionHighlightStyle:", @as(i64, 0));

    // Wrap in scroll view
    const scroll = objc.init(objc.alloc(NSScrollView));
    objc.msgSendVoidWith1(objc.id, scroll, "setDocumentView:", table);
    objc.msgSendVoidWith1(bool, scroll, "setHasVerticalScroller:", true);
    objc.msgSendVoidWith1(bool, scroll, "setAutohidesScrollers:", true);

    return scroll;
}
