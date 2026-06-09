const std = @import("std");
const objc = @import("objc.zig");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const delegate = @import("delegate.zig");
const file_list = @import("file_list.zig");
const sidebar = @import("sidebar.zig");

const NSViewMinXMargin: u64 = 1;
const NSViewWidthSizable: u64 = 2;
const NSViewMinYMargin: u64 = 8;
const NSViewHeightSizable: u64 = 16;
const NSEventModifierFlagCommand: u64 = 1 << 20;

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

pub fn msgSendRect(target: objc.id, sel_name: [:0]const u8, rect: objc.CGRect) void {
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

/// System font at `size`, used everywhere so the type ramp stays consistent.
pub fn makeSystemFont(size: f64) objc.id {
    const NSFont = objc.getClass("NSFont") orelse return null;
    return objc.msgSendWith1(objc.CGFloat, @as(objc.id, @ptrCast(NSFont)), "systemFontOfSize:", @as(objc.CGFloat, size));
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
    configureKeyLoop(s);
    focusPrimaryView(s);
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

    // Filter bar (initially 0 height / hidden)
    const filter_bar = buildFilterBar(objc.CGRect.make(0, 0, theme.window_default_width, 0));

    const split_height = theme.window_default_height - theme.toolbar_height;
    const split = buildSplitView(s, objc.CGRect.make(0, 0, theme.window_default_width, split_height));
    if (split != null) {
        setAutoresizingMask(split, NSViewWidthSizable | NSViewHeightSizable);
        objc.msgSendVoidWith1(objc.id, content, "addSubview:", split);
    }
    s.split_view = split;

    if (filter_bar != null) {
        setAutoresizingMask(filter_bar, NSViewWidthSizable | NSViewMinYMargin);
        objc.msgSendVoidWith1(objc.id, content, "addSubview:", filter_bar);
        s.filter_bar = filter_bar;
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

    // Constrain the divider so neither pane can be dragged shut.
    const NSApp = objc.msgSend(objc.getClass("NSApplication") orelse return null, "sharedApplication");
    const app_delegate = objc.msgSend(NSApp, "delegate");
    objc.msgSendVoidWith1(objc.id, split, "setDelegate:", app_delegate);

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
    if (makeToolbarSymbolButton("chevron.left", "backAction:", app_delegate)) |button| {
        msgSendRect(button, "setFrame:", objc.CGRect.make(x, control_y, button_size, button_size));
        objc.msgSendVoidWith1(objc.id, toolbar, "addSubview:", button);
        x += button_size + 8;
    }
    if (makeToolbarSymbolButton("chevron.right", "forwardAction:", app_delegate)) |button| {
        msgSendRect(button, "setFrame:", objc.CGRect.make(x, control_y, button_size, button_size));
        objc.msgSendVoidWith1(objc.id, toolbar, "addSubview:", button);
        x += button_size + 8;
    }
    if (makeToolbarSymbolButton("arrow.up", "upAction:", app_delegate)) |button| {
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

    // Editable path field (wrapped in container for padding)
    if (objc.getClass("NSTextField")) |NSTextField| {
        const path_width = @max(120.0, search_x - x - gap);
        const inset_x: f64 = 8.0;
        const inset_y: f64 = 4.0;

        // Container view with styled background/border
        const container = makeView("NSView", objc.CGRect.make(x, control_y, path_width, button_size));
        if (container != null) {
            styleToolbarField(container);
            setAutoresizingMask(container, NSViewWidthSizable);
            objc.msgSendVoidWith1(objc.id, toolbar, "addSubview:", container);
        }

        // Text field inset inside container
        const path_field = objc.autorelease(objc.msgSendWith1(
            objc.CGRect,
            objc.alloc(NSTextField),
            "initWithFrame:",
            objc.CGRect.make(inset_x, inset_y, path_width - inset_x * 2, button_size - inset_y * 2),
        ));
        objc.msgSendVoidWith1(objc.id, path_field, "setStringValue:", objc.NSString.fromSlice(s.app.currentPath()));
        objc.msgSendVoidWith1(objc.id, path_field, "setTextColor:", makeNSColor(theme.text_primary));
        objc.msgSendVoidWith1(bool, path_field, "setEditable:", true);
        objc.msgSendVoidWith1(bool, path_field, "setSelectable:", true);
        objc.msgSendVoidWith1(bool, path_field, "setBordered:", false);
        objc.msgSendVoidWith1(bool, path_field, "setBezeled:", false);
        objc.msgSendVoidWith1(bool, path_field, "setDrawsBackground:", false);
        objc.msgSendVoidWith1(bool, path_field, "setUsesSingleLineMode:", true);
        objc.msgSendVoidWith1(i64, path_field, "setLineBreakMode:", @as(i64, 2));
        objc.msgSendVoidWith1(objc.id, path_field, "setTarget:", app_delegate);
        objc.msgSendVoidWith1(objc.SEL, path_field, "setAction:", objc.sel("pathAction:"));
        if (objc.msgSend(path_field, "cell")) |cell| {
            objc.msgSendVoidWith1(bool, cell, "setSendsActionOnEndEditing:", true);
        }
        setAutoresizingMask(path_field, NSViewWidthSizable);
        s.path_field = path_field;
        if (container != null) {
            objc.msgSendVoidWith1(objc.id, container, "addSubview:", path_field);
        }
    }

    // Search field
    if (objc.getClass("NSSearchField")) |NSSearchField| {
        const search_field = objc.autorelease(objc.msgSendWith1(objc.CGRect, objc.alloc(NSSearchField), "initWithFrame:", objc.CGRect.make(search_x, control_y, search_width, button_size)));
        objc.msgSendVoidWith1(objc.id, search_field, "setPlaceholderString:", objc.NSString.fromSlice("Search (ext:pdf kind:folder size:>1mb)"));
        objc.msgSendVoidWith1(objc.id, search_field, "setTarget:", app_delegate);
        objc.msgSendVoidWith1(objc.SEL, search_field, "setAction:", objc.sel("searchAction:"));
        objc.msgSendVoidWith1(bool, search_field, "setSendsSearchStringImmediately:", true);
        setAutoresizingMask(search_field, NSViewMinXMargin);
        s.search_field = search_field;
        objc.msgSendVoidWith1(objc.id, toolbar, "addSubview:", search_field);
    }

    // Saved filters popup (replaces old category popup)
    if (objc.getClass("NSPopUpButton")) |NSPopUpButton| {
        const popup_frame = objc.CGRect.make(popup_x, control_y, popup_width, button_size);
        const popup = objc.msgSendWith2(objc.CGRect, bool, objc.alloc(NSPopUpButton), "initWithFrame:pullsDown:", popup_frame, true);
        objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice("Saved Filters"));
        // Populate from filter store
        const saved = s.app.user_state.getSavedFilters();
        for (saved) |sf| {
            objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice(sf.name));
        }
        if (saved.len == 0) {
            objc.msgSendVoidWith1(objc.id, popup, "addItemWithTitle:", objc.NSString.fromSlice("(no saved filters)"));
            if (objc.msgSend(popup, "menu")) |menu| {
                const item = objc.msgSendWith1(i64, menu, "itemAtIndex:", @as(i64, 1));
                objc.msgSendVoidWith1(bool, item, "setEnabled:", false);
            }
        } else {
            // Set represented objects + action on each saved filter item
            if (objc.msgSend(popup, "menu")) |menu| {
                for (saved, 0..) |sf, i| {
                    const item = objc.msgSendWith1(i64, menu, "itemAtIndex:", @as(i64, @intCast(i + 1)));
                    objc.msgSendVoidWith1(objc.id, item, "setRepresentedObject:", objc.NSString.fromSlice(sf.query));
                    objc.msgSendVoidWith1(objc.id, item, "setTarget:", app_delegate);
                    objc.msgSendVoidWith1(objc.SEL, item, "setAction:", objc.sel("loadSavedFilter:"));
                }
            }
        }
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
        addMenuItem(edit_menu, "Find", "focusSearch:", app_delegate, "f");
        objc.msgSendVoidWith1(objc.id, edit_item, "setSubmenu:", edit_menu);
        objc.msgSendVoidWith1(objc.id, main_menu, "addItem:", edit_item);
    }

    // Navigate menu
    {
        const nav_item = objc.init(objc.alloc(NSMenuItem));
        const nav_menu = objc.msgSendWith1(objc.id, objc.alloc(NSMenu), "initWithTitle:", objc.NSString.fromSlice("Navigate"));
        addMenuItem(nav_menu, "Back", "backAction:", app_delegate, "[");
        addMenuItem(nav_menu, "Forward", "forwardAction:", app_delegate, "]");
        addMenuItemWithModifiers(nav_menu, "Go Up", "upAction:", app_delegate, "\u{F700}", NSEventModifierFlagCommand);
        addMenuItemWithModifiers(nav_menu, "Open Selection", "openSelection:", app_delegate, "\u{F701}", NSEventModifierFlagCommand);
        addMenuItemWithModifiers(nav_menu, "Go to Containing Folder", "goToContainingFolder:", app_delegate, "g", NSEventModifierFlagCommand | (1 << 17)); // Cmd+Shift+G
        objc.msgSendVoidWith1(objc.id, nav_item, "setSubmenu:", nav_menu);
        objc.msgSendVoidWith1(objc.id, main_menu, "addItem:", nav_item);
    }

    // View menu
    {
        const view_item = objc.init(objc.alloc(NSMenuItem));
        const view_menu = objc.msgSendWith1(objc.id, objc.alloc(NSMenu), "initWithTitle:", objc.NSString.fromSlice("View"));
        addMenuItemWithModifiers(view_menu, "Show Full Path", "toggleShowFullPath:", app_delegate, "p", NSEventModifierFlagCommand | (1 << 17)); // Cmd+Shift+P
        addMenuItem(view_menu, "Keep Folders on Top", "toggleFoldersOnTop:", app_delegate, "");
        // Keep handles to the items so their check state can be toggled, and seed
        // the initial checkmarks from AppState defaults.
        if (delegate.state) |s| {
            s.show_full_path_item = objc.msgSendWith1(i64, view_menu, "itemAtIndex:", @as(i64, 0));
            if (s.show_full_path_item) |it| objc.msgSendVoidWith1(i64, it, "setState:", @as(i64, if (s.show_full_path) 1 else 0));
            s.folders_on_top_item = objc.msgSendWith1(i64, view_menu, "itemAtIndex:", @as(i64, 1));
            if (s.folders_on_top_item) |it| objc.msgSendVoidWith1(i64, it, "setState:", @as(i64, if (s.folders_on_top) 1 else 0));
        }
        objc.msgSendVoidWith1(objc.id, view_item, "setSubmenu:", view_menu);
        objc.msgSendVoidWith1(objc.id, main_menu, "addItem:", view_item);
    }

    objc.msgSendVoidWith1(objc.id, NSApp, "setMainMenu:", main_menu);
}

fn addMenuItem(menu: objc.id, title: []const u8, action: [:0]const u8, target: objc.id, key: []const u8) void {
    addMenuItemWithModifiers(menu, title, action, target, key, if (key.len > 0) NSEventModifierFlagCommand else 0);
}

fn addMenuItemWithModifiers(menu: objc.id, title: []const u8, action: [:0]const u8, target: objc.id, key: []const u8, modifiers: u64) void {
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
    objc.msgSendVoidWith1(u64, item, "setKeyEquivalentModifierMask:", modifiers);
    objc.msgSendVoidWith1(objc.id, menu, "addItem:", item);
}

fn setupIndexTimer() void {
    const NSTimer = objc.getClass("NSTimer") orelse return;
    const NSApp = objc.msgSend(objc.getClass("NSApplication") orelse return, "sharedApplication");
    const app_delegate = objc.msgSend(NSApp, "delegate");
    const func = objc.msgSendFn(*const fn (objc.id, objc.SEL, f64, objc.id, objc.SEL, objc.id, bool) callconv(.c) objc.id);
    _ = func(@ptrCast(NSTimer), objc.sel("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"), 5.0, app_delegate, objc.sel("pollIndex:"), null, true);
}

pub fn makeButton(title: []const u8, action: [:0]const u8, target: objc.id) objc.id {
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

fn makeToolbarSymbolButton(symbol_name: []const u8, action: [:0]const u8, target: objc.id) objc.id {
    const button = makeButton("", action, target);
    if (button == null) return null;
    msgSendSize(button, "setFrameSize:", .{ .width = 28, .height = 28 });
    objc.msgSendVoidWith1(i64, button, "setBezelStyle:", @as(i64, 10));
    objc.msgSendVoidWith1(bool, button, "setBordered:", false);
    objc.msgSendVoidWith1(i64, button, "setImagePosition:", @as(i64, 1));
    icons.applyImage(button, icons.symbolImage(symbol_name, 14.0, 0.0, 1), theme.toolbar_icon, 14.0);
    objc.msgSendVoidWith1(i64, button, "setImageScaling:", @as(i64, 2));
    return button;
}

fn buildFilterBar(frame: objc.CGRect) objc.id {
    const bar = makeView("NSView", frame);
    if (bar == null) return null;

    objc.msgSendVoidWith1(bool, bar, "setWantsLayer:", true);
    if (objc.msgSend(bar, "layer")) |layer| {
        const cg_color = objc.msgSend(makeNSColor(theme.filter_pill_bg), "CGColor");
        objc.msgSendVoidWith1(objc.id, layer, "setBackgroundColor:", cg_color);
    }
    return bar;
}

pub fn setFilterBarVisible(bar: objc.id, split: objc.id, visible: bool) void {
    if (bar == null) return;
    const win_frame = getFrame(bar);
    _ = win_frame;

    // Get the parent content view
    const superview = objc.msgSend(bar, "superview");
    if (superview == null) return;
    const content_frame = getFrame(superview);

    if (visible) {
        const bar_y = content_frame.size.height - theme.toolbar_height - theme.filter_bar_height;
        msgSendRect(bar, "setFrame:", objc.CGRect.make(0, bar_y, content_frame.size.width, theme.filter_bar_height));

        // Resize split view to fit below filter bar
        if (split != null) {
            msgSendRect(split, "setFrame:", objc.CGRect.make(0, 0, content_frame.size.width, bar_y));
        }
    } else {
        // Hide filter bar (zero height)
        msgSendRect(bar, "setFrame:", objc.CGRect.make(0, 0, 0, 0));

        // Restore split view full height
        if (split != null) {
            const split_height = content_frame.size.height - theme.toolbar_height;
            msgSendRect(split, "setFrame:", objc.CGRect.make(0, 0, content_frame.size.width, split_height));
        }
    }
}

pub fn makePillView(frame: objc.CGRect, label_text: []const u8, tag: i64, target: objc.id) objc.id {
    const pill = makeView("NSView", frame);
    if (pill == null) return null;

    // Rounded background
    objc.msgSendVoidWith1(bool, pill, "setWantsLayer:", true);
    if (objc.msgSend(pill, "layer")) |layer| {
        const cg_color = objc.msgSend(makeNSColor(theme.filter_pill_text_bg), "CGColor");
        objc.msgSendVoidWith1(objc.id, layer, "setBackgroundColor:", cg_color);
        msgSendFloat(layer, "setCornerRadius:", theme.pill_corner_radius);
    }

    // Label
    if (objc.getClass("NSTextField")) |NSTextField| {
        const label = objc.msgSendWith1(objc.id, @as(objc.id, @ptrCast(NSTextField)), "labelWithString:", objc.NSString.fromSlice(label_text));
        objc.msgSendVoidWith1(objc.id, label, "setTextColor:", makeNSColor(theme.filter_pill_text_color));
        msgSendRect(label, "setFrame:", objc.CGRect.make(6, 2, frame.size.width - 24, frame.size.height - 4));
        objc.msgSendVoidWith1(objc.id, label, "setFont:", makeSystemFont(theme.font_size_pill));
        objc.msgSendVoidWith1(objc.id, pill, "addSubview:", label);
    }

    // Close button "✕"
    const close_btn = makeButton("\u{2715}", "removeFilter:", target);
    if (close_btn != null) {
        msgSendRect(close_btn, "setFrame:", objc.CGRect.make(frame.size.width - 18, 2, 16, frame.size.height - 4));
        objc.msgSendVoidWith1(i64, close_btn, "setBezelStyle:", @as(i64, 10));
        objc.msgSendVoidWith1(bool, close_btn, "setBordered:", false);
        objc.msgSendVoidWith1(i64, close_btn, "setTag:", tag);
        objc.msgSendVoidWith1(objc.id, close_btn, "setFont:", makeSystemFont(theme.font_size_pill_close));
        objc.msgSendVoidWith1(objc.id, pill, "addSubview:", close_btn);
    }

    return pill;
}

pub fn getFrame(view: objc.id) objc.CGRect {
    const func = objc.msgSendFn(*const fn (objc.id, objc.SEL) callconv(.c) objc.CGRect);
    return func(view, objc.sel("frame"));
}

fn styleToolbarField(field: objc.id) void {
    objc.msgSendVoidWith1(bool, field, "setWantsLayer:", true);
    if (objc.msgSend(field, "layer")) |layer| {
        const background = objc.msgSend(makeNSColor(theme.input_background), "CGColor");
        const border = objc.msgSend(makeNSColor(theme.input_border), "CGColor");
        objc.msgSendVoidWith1(objc.id, layer, "setBackgroundColor:", background);
        objc.msgSendVoidWith1(objc.id, layer, "setBorderColor:", border);
        msgSendFloat(layer, "setBorderWidth:", 1.0);
        msgSendFloat(layer, "setCornerRadius:", theme.corner_radius);
    }
}

fn configureKeyLoop(s: *delegate.AppState) void {
    const path_field = s.path_field orelse return;
    const search_field = s.search_field orelse return;
    const category_popup = s.category_popup orelse return;
    const sidebar_view = s.sidebar_view orelse return;
    const table_view = s.table_view orelse return;

    objc.msgSendVoidWith1(objc.id, path_field, "setNextKeyView:", search_field);
    objc.msgSendVoidWith1(objc.id, search_field, "setNextKeyView:", category_popup);
    objc.msgSendVoidWith1(objc.id, category_popup, "setNextKeyView:", sidebar_view);
    objc.msgSendVoidWith1(objc.id, sidebar_view, "setNextKeyView:", table_view);
    objc.msgSendVoidWith1(objc.id, table_view, "setNextKeyView:", path_field);
}

fn focusPrimaryView(s: *delegate.AppState) void {
    const win = s.window_id orelse return;
    const table_view = s.table_view orelse return;
    objc.msgSendVoidWith1(objc.id, win, "setInitialFirstResponder:", table_view);
    _ = objc.msgSendBoolWith1(objc.id, win, "makeFirstResponder:", table_view);
}
