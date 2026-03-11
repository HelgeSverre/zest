const objc = @import("objc.zig");
const theme = @import("theme.zig");
const delegate = @import("delegate.zig");
const window = @import("window.zig");

const NSViewMinYMargin: u64 = 8;
const NSViewWidthSizable: u64 = 2;
const NSViewHeightSizable: u64 = 16;

fn makeView(class_name: [:0]const u8, frame: objc.CGRect) objc.id {
    const cls = objc.getClass(class_name) orelse return null;
    return objc.autorelease(objc.msgSendWith1(objc.CGRect, objc.alloc(cls), "initWithFrame:", frame));
}

fn setAutoresizingMask(view: objc.id, mask: u64) void {
    objc.msgSendVoidWith1(u64, view, "setAutoresizingMask:", mask);
}

pub fn createSidebar(s: *delegate.AppState, frame: objc.CGRect) objc.id {
    const NSScrollView = objc.getClass("NSScrollView") orelse return null;
    const NSTableView = objc.getClass("NSTableView") orelse return null;
    const NSTableColumn = objc.getClass("NSTableColumn") orelse return null;
    const NSTextField = objc.getClass("NSTextField") orelse return null;

    const container = makeView("NSView", frame);
    if (container == null) return null;
    objc.msgSendVoidWith1(bool, container, "setWantsLayer:", true);
    if (objc.msgSend(container, "layer")) |layer| {
        const cg_color = objc.msgSend(window.makeNSColor(theme.sidebar), "CGColor");
        objc.msgSendVoidWith1(objc.id, layer, "setBackgroundColor:", cg_color);
    }

    const title_frame = objc.CGRect.make(
        theme.content_padding,
        frame.size.height - theme.sidebar_header_height - 8,
        frame.size.width - (theme.content_padding * 2),
        theme.sidebar_header_height,
    );
    const title = objc.msgSendWith1(objc.id, @as(objc.id, @ptrCast(NSTextField)), "labelWithString:", objc.NSString.fromSlice("PINNED"));
    objc.msgSendVoidWith1(objc.id, title, "setTextColor:", window.makeNSColor(theme.text_secondary));
    objc.msgSendVoidWith1(objc.CGRect, title, "setFrame:", title_frame);
    setAutoresizingMask(title, NSViewWidthSizable | NSViewMinYMargin);
    objc.msgSendVoidWith1(objc.id, container, "addSubview:", title);

    const scroll_height = if (frame.size.height > theme.sidebar_header_height + 8)
        frame.size.height - theme.sidebar_header_height - 8
    else
        frame.size.height;
    const scroll_frame = objc.CGRect.make(0, 0, frame.size.width, scroll_height);

    const table = objc.autorelease(objc.msgSendWith1(objc.CGRect, objc.alloc(NSTableView), "initWithFrame:", scroll_frame));
    s.sidebar_view = table;
    setAutoresizingMask(table, NSViewWidthSizable | NSViewHeightSizable);

    const col = objc.msgSendWith1(objc.id, objc.alloc(NSTableColumn), "initWithIdentifier:", objc.NSString.fromSlice("pin"));
    const setWidth = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGFloat) callconv(.c) void);
    setWidth(col, objc.sel("setWidth:"), frame.size.width - (theme.content_padding * 2));
    objc.msgSendVoidWith1(objc.id, table, "addTableColumn:", col);
    objc.msgSendVoidWith1(objc.id, table, "setHeaderView:", null);

    const ds_cls = objc.getClass("ZestSidebarDataSource") orelse return null;
    const ds = objc.init(objc.alloc(ds_cls));
    objc.msgSendVoidWith1(objc.id, table, "setDataSource:", ds);
    objc.msgSendVoidWith1(objc.id, table, "setDelegate:", ds);
    objc.msgSendVoidWith1(objc.id, table, "setBackgroundColor:", window.makeNSColor(theme.sidebar));
    const setRowHeight = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGFloat) callconv(.c) void);
    setRowHeight(table, objc.sel("setRowHeight:"), theme.sidebar_row_height);

    const scroll = objc.autorelease(objc.msgSendWith1(objc.CGRect, objc.alloc(NSScrollView), "initWithFrame:", scroll_frame));
    setAutoresizingMask(scroll, NSViewWidthSizable | NSViewHeightSizable);
    objc.msgSendVoidWith1(objc.id, scroll, "setDocumentView:", table);
    objc.msgSendVoidWith1(bool, scroll, "setHasVerticalScroller:", true);
    objc.msgSendVoidWith1(bool, scroll, "setAutohidesScrollers:", true);
    objc.msgSendVoidWith1(objc.id, container, "addSubview:", scroll);

    return container;
}
