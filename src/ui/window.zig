const std = @import("std");
const objc = @import("objc.zig");
const theme = @import("theme.zig");
const delegate = @import("delegate.zig");
const file_list = @import("file_list.zig");
const sidebar = @import("sidebar.zig");

const NSViewMinXMargin: u64 = 1;
const NSViewWidthSizable: u64 = 2;
const NSViewMinYMargin: u64 = 8;
const NSViewHeightSizable: u64 = 16;

fn msgSendSize(target: objc.id, sel_name: [:0]const u8, size: objc.CGSize) void {
    const func = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGSize) callconv(.c) void);
    func(target, objc.sel(sel_name), size);
}

fn msgSendFloat(target: objc.id, sel_name: [:0]const u8, val: objc.CGFloat) void {
    const func = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGFloat) callconv(.c) void);
    func(target, objc.sel(sel_name), val);
}

fn msgSendFloatI64(target: objc.id, sel_name: [:0]const u8, val: objc.CGFloat, idx: i64) void {
    const func = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGFloat, i64) callconv(.c) void);
    func(target, objc.sel(sel_name), val, idx);
}

fn msgSendRect(target: objc.id, sel_name: [:0]const u8, rect: objc.CGRect) void {
    const func = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGRect) callconv(.c) void);
    func(target, objc.sel(sel_name), rect);
}

fn setAutoresizingMask(view: objc.id, mask: u64) void {
    objc.msgSendVoidWith1(u64, view, "setAutoresizingMask:", mask);
}

fn makeView(class_name: [:0]const u8, frame: objc.CGRect) objc.id {
    const cls = objc.getClass(class_name) orelse return null;
    return objc.autorelease(objc.msgSendWith1(objc.CGRect, objc.alloc(cls), "initWithFrame:", frame));
}

pub fn makeNSColor(color: theme.Color) objc.id {
    const NSColor = objc.getClass("NSColor") orelse return null;
    const func = objc.msgSendFn(*const fn (objc.id, objc.SEL, f64, f64, f64, f64) callconv(.c) objc.id);
    return func(@ptrCast(NSColor), objc.sel("colorWithRed:green:blue:alpha:"), color.r, color.g, color.b, color.a);
}

pub fn createMainWindow() void {
    const s = delegate.state orelse return;

    // Create NSWindow
    const NSWindow = objc.getClass("NSWindow") orelse return;
    const frame = objc.CGRect.make(0, 0, theme.window_default_width, theme.window_default_height);
    const style_mask: u64 = 1 | 2 | 4 | 8; // titled | closable | miniaturizable | resizable
    const win = objc.msgSendWith4(objc.CGRect, u64, u64, bool, objc.alloc(NSWindow), "initWithContentRect:styleMask:backing:defer:", frame, style_mask, @as(u64, 2), false);
    s.window_id = win;

    if (win == null) return;

    // Min size
    msgSendSize(win, "setMinSize:", .{ .width = theme.window_min_width, .height = theme.window_min_height });

    // Title
    objc.msgSendVoidWith1(objc.id, win, "setTitle:", objc.NSString.fromSlice("Zest"));

    // Force dark appearance
    if (objc.getClass("NSAppearance")) |NSAppearance| {
        const dark_appearance = objc.msgSendWith1(objc.id, @as(objc.id, @ptrCast(NSAppearance)), "appearanceNamed:", objc.NSString.fromSlice("NSAppearanceNameDarkAqua"));
        objc.msgSendVoidWith1(objc.id, win, "setAppearance:", dark_appearance);
    }

    // Background color
    objc.msgSendVoidWith1(objc.id, win, "setBackgroundColor:", makeNSColor(theme.background));

    // Build content: toolbar on top, split view below
    const content = buildFullContentView(s);
    objc.msgSendVoidWith1(objc.id, win, "setContentView:", content);

    // Build main menu (keyboard shortcuts)
    buildMainMenu();

    // Set up index polling timer (every 5 seconds)
    setupIndexTimer();

    // Center and show
    objc.msgSendVoid(win, "center");
    objc.msgSendVoidWith1(objc.id, win, "makeKeyAndOrderFront:", null);

    // Initial data load
    delegate.refreshAll();
}

fn buildFullContentView(s: *delegate.AppState) objc.id {
    const content_frame = objc.CGRect.make(0, 0, theme.window_default_width, theme.window_default_height);
    const content = makeView("NSView", content_frame);
    if (content == null) return null;

    objc.msgSendVoidWith1(bool, content, "setWantsLayer:", true);
    if (objc.msgSend(content, "layer")) |layer| {
        const cg_color = objc.msgSend(makeNSColor(theme.background), "CGColor");
        objc.msgSendVoidWith1(objc.id, layer, "setBackgroundColor:", cg_color);
    }

    const split_height = theme.window_default_height - theme.toolbar_height;
    const split = buildSplitView(s, objc.CGRect.make(0, 0, theme.window_default_width, split_height));
    if (split != null) {
        setAutoresizingMask(split, NSViewWidthSizable | NSViewHeightSizable);
        objc.msgSendVoidWith1(objc.id, content, "addSubview:", split);
    }

    const toolbar = buildToolbarView(s, objc.CGRect.make(0, split_height, theme.window_default_width, theme.toolbar_height));
    if (toolbar != null) {
        setAutoresizingMask(toolbar, NSViewWidthSizable | NSViewMinYMargin);
        objc.msgSendVoidWith1(objc.id, content, "addSubview:", toolbar);
    }

    return content;
}

fn buildSplitView(s: *delegate.AppState, frame: objc.CGRect) objc.id {
    const NSSplitView = objc.getClass("NSSplitView") orelse return null;
    const split = objc.autorelease(objc.msgSendWith1(objc.CGRect, objc.alloc(NSSplitView), "initWithFrame:", frame));
    objc.msgSendVoidWith1(bool, split, "setVertical:", true);
    objc.msgSendVoidWith1(i64, split, "setDividerStyle:", @as(i64, 1));

    if (sidebar.createSidebar(s, objc.CGRect.make(0, 0, theme.sidebar_width, frame.size.height))) |sv| {
        setAutoresizingMask(sv, NSViewHeightSizable);
        objc.msgSendVoidWith1(objc.id, split, "addSubview:", sv);
    }

    const file_width = if (frame.size.width > theme.sidebar_width) frame.size.width - theme.sidebar_width else frame.size.width;
    if (file_list.createFileList(s, objc.CGRect.make(theme.sidebar_width, 0, file_width, frame.size.height))) |lv| {
        setAutoresizingMask(lv, NSViewWidthSizable | NSViewHeightSizable);
        objc.msgSendVoidWith1(objc.id, split, "addSubview:", lv);
    }

    msgSendFloatI64(split, "setPosition:ofDividerAtIndex:", theme.sidebar_width, 0);
    return split;
}

fn buildToolbarView(s: *delegate.AppState, frame: objc.CGRect) objc.id {
    const toolbar = makeView("NSView", frame);
    if (toolbar == null) return null;

    objc.msgSendVoidWith1(bool, toolbar, "setWantsLayer:", true);
    if (objc.msgSend(toolbar, "layer")) |layer| {
        const cg_color = objc.msgSend(makeNSColor(theme.toolbar), "CGColor");
        objc.msgSendVoidWith1(objc.id, layer, "setBackgroundColor:", cg_color);
    }

    const NSApp = objc.msgSend(objc.getClass("NSApplication") orelse return null, "sharedApplication");
    const app_delegate = objc.msgSend(NSApp, "delegate");
    const padding = theme.content_padding;
    const button_size = 28.0;
    const control_y = @max(0.0, @divExact(frame.size.height - button_size, 2.0));
    const popup_width = 140.0;
    const search_width = 260.0;
    const gap = 10.0;
    const popup_x = frame.size.width - padding - popup_width;
    const search_x = popup_x - gap - search_width;
    var x = padding;

    // Navigation buttons
    if (makeToolbarButton("\xE2\x86\x90", "backAction:", app_delegate)) |button| {
        msgSendRect(button, "setFrame:", objc.CGRect.make(x, control_y, button_size, button_size));
        objc.msgSendVoidWith1(objc.id, toolbar, "addSubview:", button);
        x += button_size + 8;
    }
    if (makeToolbarButton("\xE2\x86\x92", "forwardAction:", app_delegate)) |button| {
        msgSendRect(button, "setFrame:", objc.CGRect.make(x, control_y, button_size, button_size));
        objc.msgSendVoidWith1(objc.id, toolbar, "addSubview:", button);
        x += button_size + 8;
    }
    if (makeToolbarButton("\xE2\x86\x91", "upAction:", app_delegate)) |button| {
        msgSendRect(button, "setFrame:", objc.CGRect.make(x, control_y, button_size, button_size));
        objc.msgSendVoidWith1(objc.id, toolbar, "addSubview:", button);
        x += button_size + 12;
    }

    if (objc.getClass("NSTextField")) |NSTextField| {
        const title_label = objc.msgSendWith1(objc.id, @as(objc.id, @ptrCast(NSTextField)), "labelWithString:", objc.NSString.fromSlice("ZEST"));
        objc.msgSendVoidWith1(objc.id, title_label, "setTextColor:", makeNSColor(theme.text_bright));
        msgSendRect(title_label, "setFrame:", objc.CGRect.make(x, control_y + 4, 44, 20));
        objc.msgSendVoidWith1(objc.id, toolbar, "addSubview:", title_label);
        x += 54;
    }

    // Path label
    if (objc.getClass("NSTextField")) |NSTextField| {
        const path_label = objc.msgSendWith1(objc.id, @as(objc.id, @ptrCast(NSTextField)), "labelWithString:", objc.NSString.fromSlice(s.app.currentPath()));
        objc.msgSendVoidWith1(objc.id, path_label, "setTextColor:", makeNSColor(theme.text_secondary));
        objc.msgSendVoidWith1(bool, path_label, "setUsesSingleLineMode:", true);
        objc.msgSendVoidWith1(i64, path_label, "setLineBreakMode:", @as(i64, 5));
        const path_width = @max(120.0, search_x - x - gap);
        msgSendRect(path_label, "setFrame:", objc.CGRect.make(x, control_y + 4, path_width, 20));
        setAutoresizingMask(path_label, NSViewWidthSizable);
        s.path_label = path_label;
        objc.msgSendVoidWith1(objc.id, toolbar, "addSubview:", path_label);
    }

    // Search field
    if (objc.getClass("NSSearchField")) |NSSearchField| {
        const search_field = objc.autorelease(objc.msgSendWith1(objc.CGRect, objc.alloc(NSSearchField), "initWithFrame:", objc.CGRect.make(search_x, control_y, search_width, button_size)));
        objc.msgSendVoidWith1(objc.id, search_field, "setPlaceholderString:", objc.NSString.fromSlice("Search Everywhere"));
        objc.msgSendVoidWith1(objc.id, search_field, "setTarget:", app_delegate);
        objc.msgSendVoidWith1(objc.SEL, search_field, "setAction:", objc.sel("searchAction:"));
        objc.msgSendVoidWith1(bool, search_field, "setSendsSearchStringImmediately:", true);
        setAutoresizingMask(search_field, NSViewMinXMargin);
        s.search_field = search_field;
        objc.msgSendVoidWith1(objc.id, toolbar, "addSubview:", search_field);
    }

    // Category filter popup
    if (objc.getClass("NSPopUpButton")) |NSPopUpButton| {
        const popup_frame = objc.CGRect.make(popup_x, control_y, popup_width, button_size);
        const popup = objc.msgSendWith2(objc.CGRect, bool, objc.alloc(NSPopUpButton), "initWithFrame:pullsDown:", popup_frame, false);
        objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice("All"));
        const categories = [_][]const u8{ "Images", "Text", "Documents", "Spreadsheets", "Audio", "Video", "Code", "Archives" };
        for (categories) |cat| {
            objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice(cat));
        }
        objc.msgSendVoidWith1(objc.id, popup, "setTarget:", app_delegate);
        objc.msgSendVoidWith1(objc.SEL, popup, "setAction:", objc.sel("categoryChanged:"));
        setAutoresizingMask(popup, NSViewMinXMargin);
        s.category_popup = popup;
        objc.msgSendVoidWith1(objc.id, toolbar, "addSubview:", popup);
    }

    return toolbar;
}

fn buildMainMenu() void {
    const NSMenu = objc.getClass("NSMenu") orelse return;
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const NSApp = objc.msgSend(objc.getClass("NSApplication") orelse return, "sharedApplication");
    const app_delegate = objc.msgSend(NSApp, "delegate");

    const main_menu = objc.init(objc.alloc(NSMenu));

    // App menu
    {
        const app_menu_item = objc.init(objc.alloc(NSMenuItem));
        const app_menu = objc.init(objc.alloc(NSMenu));
        addMenuItem(app_menu, "Quit Zest", "terminate:", NSApp, "q");
        objc.msgSendVoidWith1(objc.id, app_menu_item, "setSubmenu:", app_menu);
        objc.msgSendVoidWith1(objc.id, main_menu, "addItem:", app_menu_item);
    }

    // File menu
    {
        const file_item = objc.init(objc.alloc(NSMenuItem));
        const file_menu = objc.msgSendWith1(objc.id, objc.alloc(NSMenu), "initWithTitle:", objc.NSString.fromSlice("File"));
        addMenuItem(file_menu, "Close Window", "performClose:", null, "w");
        objc.msgSendVoidWith1(objc.id, file_item, "setSubmenu:", file_menu);
        objc.msgSendVoidWith1(objc.id, main_menu, "addItem:", file_item);
    }

    // Edit menu
    {
        const edit_item = objc.init(objc.alloc(NSMenuItem));
        const edit_menu = objc.msgSendWith1(objc.id, objc.alloc(NSMenu), "initWithTitle:", objc.NSString.fromSlice("Edit"));
        addMenuItem(edit_menu, "Copy", "copy:", null, "c");
        addMenuItem(edit_menu, "Select All", "selectAll:", null, "a");
        objc.msgSendVoidWith1(objc.id, edit_item, "setSubmenu:", edit_menu);
        objc.msgSendVoidWith1(objc.id, main_menu, "addItem:", edit_item);
    }

    // Navigate menu
    {
        const nav_item = objc.init(objc.alloc(NSMenuItem));
        const nav_menu = objc.msgSendWith1(objc.id, objc.alloc(NSMenu), "initWithTitle:", objc.NSString.fromSlice("Navigate"));
        addMenuItem(nav_menu, "Back", "backAction:", app_delegate, "[");
        addMenuItem(nav_menu, "Forward", "forwardAction:", app_delegate, "]");
        objc.msgSendVoidWith1(objc.id, nav_item, "setSubmenu:", nav_menu);
        objc.msgSendVoidWith1(objc.id, main_menu, "addItem:", nav_item);
    }

    objc.msgSendVoidWith1(objc.id, NSApp, "setMainMenu:", main_menu);
}

fn addMenuItem(menu: objc.id, title: []const u8, action: [:0]const u8, target: objc.id, key: []const u8) void {
    const NSMenuItem = objc.getClass("NSMenuItem") orelse return;
    const item = objc.msgSendWith3(
        objc.id,
        objc.SEL,
        objc.id,
        objc.alloc(NSMenuItem),
        "initWithTitle:action:keyEquivalent:",
        objc.NSString.fromSlice(title),
        objc.sel(action),
        objc.NSString.fromSlice(key),
    );
    if (target) |t| {
        objc.msgSendVoidWith1(objc.id, item, "setTarget:", t);
    }
    objc.msgSendVoidWith1(objc.id, menu, "addItem:", item);
}

fn setupIndexTimer() void {
    const NSTimer = objc.getClass("NSTimer") orelse return;
    const NSApp = objc.msgSend(objc.getClass("NSApplication") orelse return, "sharedApplication");
    const app_delegate = objc.msgSend(NSApp, "delegate");
    const func = objc.msgSendFn(*const fn (objc.id, objc.SEL, f64, objc.id, objc.SEL, objc.id, bool) callconv(.c) objc.id);
    _ = func(@ptrCast(NSTimer), objc.sel("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"), 5.0, app_delegate, objc.sel("pollIndex:"), null, true);
}

fn makeButton(title: []const u8, action: [:0]const u8, target: objc.id) objc.id {
    const NSButton = objc.getClass("NSButton") orelse return null;
    return objc.msgSendWith3(
        objc.id,
        objc.id,
        objc.SEL,
        @as(objc.id, @ptrCast(NSButton)),
        "buttonWithTitle:target:action:",
        objc.NSString.fromSlice(title),
        target,
        objc.sel(action),
    );
}

fn makeToolbarButton(title: []const u8, action: [:0]const u8, target: objc.id) objc.id {
    const button = makeButton(title, action, target);
    if (button == null) return null;
    msgSendSize(button, "setFrameSize:", .{ .width = 28, .height = 28 });
    objc.msgSendVoidWith1(i64, button, "setBezelStyle:", @as(i64, 1));
    return button;
}
