const std = @import("std");
const objc = @import("objc.zig");
const theme = @import("theme.zig");
const delegate = @import("delegate.zig");
const file_list = @import("file_list.zig");
const sidebar = @import("sidebar.zig");

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
    // Outer vertical stack: toolbar on top, split view below
    const NSStackView = objc.getClass("NSStackView") orelse return null;
    const outer = objc.init(objc.alloc(NSStackView));
    objc.msgSendVoidWith1(i64, outer, "setOrientation:", @as(i64, 1)); // vertical
    msgSendFloat(outer, "setSpacing:", 0.0);
    objc.msgSendVoidWith1(i64, outer, "setDistribution:", @as(i64, 1)); // gravityAreas
    const setInsets = objc.msgSendFn(*const fn (objc.id, objc.SEL, f64, f64, f64, f64) callconv(.c) void);
    setInsets(outer, objc.sel("setEdgeInsets:"), 0, 0, 0, 0);

    // Build toolbar row
    const toolbar = buildToolbarView(s);
    if (toolbar) |tb| {
        objc.msgSendVoidWith2(objc.id, i64, outer, "addView:inGravity:", tb, @as(i64, 1)); // top
    }

    // Build split view (sidebar + file list)
    const NSSplitView = objc.getClass("NSSplitView") orelse return outer;
    const split = objc.init(objc.alloc(NSSplitView));
    objc.msgSendVoidWith1(bool, split, "setVertical:", true);

    if (sidebar.createSidebar(s)) |sv| {
        objc.msgSendVoidWith1(objc.id, split, "addSubview:", sv);
    }
    if (file_list.createFileList(s)) |lv| {
        objc.msgSendVoidWith1(objc.id, split, "addSubview:", lv);
    }

    msgSendFloatI64(split, "setPosition:ofDividerAtIndex:", theme.sidebar_width, 0);

    // Split view fills remaining space
    objc.msgSendVoidWith2(objc.id, i64, outer, "addView:inGravity:", split, @as(i64, 3)); // bottom

    // Low hugging priority so split view expands
    const setHugging = objc.msgSendFn(*const fn (objc.id, objc.SEL, f32, i64) callconv(.c) void);
    setHugging(split, objc.sel("setContentHuggingPriority:forOrientation:"), 1.0, @as(i64, 1));

    return outer;
}

fn buildToolbarView(s: *delegate.AppState) objc.id {
    const NSStackView = objc.getClass("NSStackView") orelse return null;
    const toolbar_stack = objc.init(objc.alloc(NSStackView));

    objc.msgSendVoidWith1(i64, toolbar_stack, "setOrientation:", @as(i64, 0)); // horizontal
    msgSendFloat(toolbar_stack, "setSpacing:", 8.0);

    const NSApp = objc.msgSend(objc.getClass("NSApplication") orelse return null, "sharedApplication");
    const app_delegate = objc.msgSend(NSApp, "delegate");

    // Navigation buttons
    addViewToStack(toolbar_stack, makeButton("\xE2\x86\x90", "backAction:", app_delegate)); // ←
    addViewToStack(toolbar_stack, makeButton("\xE2\x86\x92", "forwardAction:", app_delegate)); // →
    addViewToStack(toolbar_stack, makeButton("\xE2\x86\x91", "upAction:", app_delegate)); // ↑

    // Path label
    if (objc.getClass("NSTextField")) |NSTextField| {
        const path_label = objc.msgSendWith1(objc.id, @as(objc.id, @ptrCast(NSTextField)), "labelWithString:", objc.NSString.fromSlice(s.app.currentPath()));
        objc.msgSendVoidWith1(objc.id, path_label, "setTextColor:", makeNSColor(theme.text_secondary));
        s.path_label = path_label;
        addViewToStack(toolbar_stack, path_label);
    }

    // Search field
    if (objc.getClass("NSSearchField")) |NSSearchField| {
        const search_field = objc.init(objc.alloc(NSSearchField));
        objc.msgSendVoidWith1(objc.id, search_field, "setPlaceholderString:", objc.NSString.fromSlice("Search..."));
        objc.msgSendVoidWith1(objc.id, search_field, "setTarget:", app_delegate);
        objc.msgSendVoidWith1(objc.SEL, search_field, "setAction:", objc.sel("searchAction:"));
        objc.msgSendVoidWith1(bool, search_field, "setSendsSearchStringImmediately:", true);
        s.search_field = search_field;
        addViewToStack(toolbar_stack, search_field);
    }

    // Category filter popup
    if (objc.getClass("NSPopUpButton")) |NSPopUpButton| {
        const popup_frame = objc.CGRect.make(0, 0, 120, 24);
        const popup = objc.msgSendWith2(objc.CGRect, bool, objc.alloc(NSPopUpButton), "initWithFrame:pullsDown:", popup_frame, false);
        objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice("All"));
        const categories = [_][]const u8{ "Images", "Text", "Documents", "Spreadsheets", "Audio", "Video", "Code", "Archives" };
        for (categories) |cat| {
            objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice(cat));
        }
        objc.msgSendVoidWith1(objc.id, popup, "setTarget:", app_delegate);
        objc.msgSendVoidWith1(objc.SEL, popup, "setAction:", objc.sel("categoryChanged:"));
        s.category_popup = popup;
        addViewToStack(toolbar_stack, popup);
    }

    // Toolbar background
    objc.msgSendVoidWith1(bool, toolbar_stack, "setWantsLayer:", true);
    if (objc.msgSend(toolbar_stack, "layer")) |layer| {
        const cg_color = objc.msgSend(makeNSColor(theme.toolbar), "CGColor");
        objc.msgSendVoidWith1(objc.id, layer, "setBackgroundColor:", cg_color);
    }

    return toolbar_stack;
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

fn addViewToStack(stack: objc.id, view: objc.id) void {
    if (view == null) return;
    objc.msgSendVoidWith2(objc.id, i64, stack, "addView:inGravity:", view, @as(i64, 1));
}
