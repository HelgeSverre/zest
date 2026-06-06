const types = @import("../core/types.zig");

/// GitHub Dark theme color constants.
/// All colors are RGBA (0.0–1.0).
pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f64, @floatFromInt(r)) / 255.0,
            .g = @as(f64, @floatFromInt(g)) / 255.0,
            .b = @as(f64, @floatFromInt(b)) / 255.0,
            .a = 1.0,
        };
    }
};

// Main backgrounds
pub const background = Color.rgb(0x0D, 0x11, 0x17); // #0D1117 - main content area
pub const toolbar = Color.rgb(0x16, 0x1B, 0x22); // #161B22 - toolbar/header
pub const sidebar = Color.rgb(0x16, 0x1B, 0x22); // #161B22 - sidebar
pub const border = Color.rgb(0x30, 0x36, 0x3D); // #30363D - borders/dividers
pub const input_background = Color.rgb(0x0D, 0x11, 0x17); // #0D1117 - toolbar field fill
pub const input_border = Color.rgb(0x30, 0x36, 0x3D); // #30363D - field border
pub const input_border_focus = Color.rgb(0x1F, 0x6F, 0xEB); // #1F6FEB - focused field border

// Selection and hover
pub const selection = Color.rgb(0x1F, 0x6F, 0xEB); // #1F6FEB - selected row (blue accent)
pub const hover = Color.rgb(0x1C, 0x21, 0x28); // #1C2128 - hover highlight
pub const focus_border = Color.rgb(0x58, 0xA6, 0xFF); // #58A6FF - focused element border

// Text
pub const text_primary = Color.rgb(0xE6, 0xED, 0xF3); // #E6EDF3 - primary text
pub const text_secondary = Color.rgb(0x8B, 0x94, 0x9E); // #8B949E - secondary/dimmed text
pub const text_bright = Color.rgb(0xF0, 0xF6, 0xFC); // #F0F6FC - bright/emphasized text
pub const text_link = Color.rgb(0x58, 0xA6, 0xFF); // #58A6FF - link/accent text
pub const icon_muted = Color.rgb(0x8B, 0x94, 0x9E); // #8B949E - neutral icon tint
pub const toolbar_icon = Color.rgb(0xE6, 0xED, 0xF3); // #E6EDF3 - toolbar symbol tint

// Syntax/category colors (for file type indicators)
pub const color_directory = Color.rgb(0xE3, 0xB3, 0x41); // #E3B341 - yellow, directories
pub const color_code = Color.rgb(0x3F, 0xB9, 0x50); // #3FB950 - green, code files
pub const color_images = Color.rgb(0x58, 0xA6, 0xFF); // #58A6FF - blue, images
pub const color_documents = Color.rgb(0xD2, 0xA8, 0xFF); // #D2A8FF - purple, documents
pub const color_audio = Color.rgb(0xBC, 0x8C, 0xFF); // #BC8CFF - violet, audio
pub const color_video = Color.rgb(0xFF, 0x7B, 0x72); // #FF7B72 - red, video
pub const color_archives = Color.rgb(0x8B, 0x94, 0x9E); // #8B949E - gray, archives
pub const color_text = Color.rgb(0xE6, 0xED, 0xF3); // #E6EDF3 - default, text
pub const icon_directory = Color.rgb(0x6F, 0xA8, 0xF6); // #6FA8F6 - folder icon (matches the "Blue" folder-color preset)

// Button/control
pub const button_bg = Color.rgb(0x21, 0x26, 0x2D); // #21262D
pub const button_hover = Color.rgb(0x30, 0x36, 0x3D); // #30363D
pub const button_pressed = Color.rgb(0x16, 0x1B, 0x22); // #161B22

// Filter bar / pills
pub const filter_bar_height: f64 = 32.0;
pub const filter_pill_bg = Color.rgb(0x16, 0x1B, 0x22); // filter bar background
pub const filter_pill_text_bg = Color.rgb(0x30, 0x36, 0x3D); // pill background
pub const filter_pill_text_color = Color.rgb(0xE6, 0xED, 0xF3); // pill text
pub const filter_pill_close = Color.rgb(0x8B, 0x94, 0x9E); // pill close button
pub const quick_filter_gap: f64 = 4.0;

// Scrollbar
pub const scrollbar_track = Color.rgb(0x0D, 0x11, 0x17); // same as background
pub const scrollbar_thumb = Color.rgb(0x30, 0x36, 0x3D); // #30363D

// Window
pub const window_min_width: f64 = 800;
pub const window_min_height: f64 = 600;
pub const window_default_width: f64 = 1100;
pub const window_default_height: f64 = 700;
pub const sidebar_width: f64 = 220;
pub const toolbar_height: f64 = 52;
pub const sidebar_header_height: f64 = 30;
pub const file_row_height: f64 = 30;
pub const sidebar_row_height: f64 = 28;
pub const content_padding: f64 = 12;

// Rounded chrome — one source of truth so sibling surfaces match.
pub const corner_radius: f64 = 6.0; // toolbar fields, larger chrome
pub const pill_corner_radius: f64 = 4.0; // small filter pills
pub const row_selection_inset: f64 = 6.0; // horizontal inset for the selection pill
pub const row_selection_radius: f64 = 5.0; // selection pill corner radius

// Type ramp — shared so panes and toolbar don't drift.
pub const font_size_row: f64 = 13; // file list / sidebar primary rows
pub const font_size_secondary: f64 = 12; // size / modified / type columns
pub const font_size_pill: f64 = 11; // filter pill label
pub const font_size_pill_close: f64 = 10; // filter pill close button

pub fn fileIconTint(category: types.FileCategory) Color {
    return switch (category) {
        .images => Color.rgb(0x58, 0xA6, 0xFF), // blue
        .text => icon_muted,
        .documents => Color.rgb(0xD2, 0xA8, 0xFF), // purple
        .spreadsheets => Color.rgb(0x3F, 0xB9, 0x50), // green
        .audio => Color.rgb(0xBC, 0x8C, 0xFF), // violet
        .video => Color.rgb(0xFF, 0x7B, 0x72), // red
        .code => Color.rgb(0x79, 0xC0, 0xFF), // light blue
        .archives => Color.rgb(0x8B, 0x94, 0x9E), // muted
        .uncategorized => icon_muted,
    };
}
