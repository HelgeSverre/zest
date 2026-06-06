const objc = @import("objc.zig");
const theme = @import("theme.zig");
const types = @import("../core/types.zig");
const folder_colors = @import("../core/folder_colors.zig");

fn makeNSColor(color: theme.Color) objc.id {
    const NSColor = objc.getClass("NSColor") orelse return null;
    const func = objc.msgSendFn(*const fn (objc.id, objc.SEL, f64, f64, f64, f64) callconv(.c) objc.id);
    return func(@ptrCast(NSColor), objc.sel("colorWithRed:green:blue:alpha:"), color.r, color.g, color.b, color.a);
}

fn msgSendSize(target: objc.id, sel_name: [:0]const u8, size: objc.CGSize) void {
    const func = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGSize) callconv(.c) void);
    func(target, objc.sel(sel_name), size);
}

pub fn fromFolderColor(color: folder_colors.FolderColor) theme.Color {
    return .{
        .r = @as(f64, @floatFromInt(color.red)) / 255.0,
        .g = @as(f64, @floatFromInt(color.green)) / 255.0,
        .b = @as(f64, @floatFromInt(color.blue)) / 255.0,
        .a = @as(f64, @floatFromInt(color.alpha)) / 255.0,
    };
}

pub fn symbolImage(name: []const u8, point_size: f64, weight: f64, scale: i64) objc.id {
    const NSImage = objc.getClass("NSImage") orelse return null;
    const base = objc.msgSendWith2(
        objc.id,
        objc.id,
        @as(objc.id, @ptrCast(NSImage)),
        "imageWithSystemSymbolName:accessibilityDescription:",
        objc.NSString.fromSlice(name),
        null,
    );
    if (base == null) return null;

    const NSImageSymbolConfiguration = objc.getClass("NSImageSymbolConfiguration") orelse return base;
    const config_fn = objc.msgSendFn(*const fn (objc.id, objc.SEL, objc.CGFloat, objc.CGFloat, i64) callconv(.c) objc.id);
    const config = config_fn(
        @ptrCast(NSImageSymbolConfiguration),
        objc.sel("configurationWithPointSize:weight:scale:"),
        point_size,
        weight,
        scale,
    );
    if (config == null) return base;
    return objc.msgSendWith1(objc.id, base, "imageWithSymbolConfiguration:", config);
}

pub fn fileSymbolName(kind: types.FileKind, category: types.FileCategory) []const u8 {
    if (kind == .directory) return "folder.fill";
    return switch (category) {
        .images => "photo",
        .text => "text.alignleft",
        .documents => "doc.text.fill",
        .spreadsheets => "tablecells.fill",
        .audio => "music.note",
        .video => "film.fill",
        .code => "chevron.left.forwardslash.chevron.right",
        .archives => "archivebox.fill",
        .uncategorized => "doc.fill",
    };
}

pub fn iconTint(kind: types.FileKind, category: types.FileCategory, color_override: ?folder_colors.FolderColor) theme.Color {
    if (kind == .directory) {
        if (color_override) |color| return fromFolderColor(color);
        return theme.icon_directory;
    }
    return theme.fileIconTint(category);
}

pub fn applyImage(view: objc.id, image: objc.id, tint: theme.Color, size: f64) void {
    if (view == null or image == null) return;
    msgSendSize(image, "setSize:", .{ .width = size, .height = size });
    objc.msgSendVoidWith1(objc.id, view, "setImage:", image);
    objc.msgSendVoidWith1(objc.id, view, "setContentTintColor:", makeNSColor(tint));
}
