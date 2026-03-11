/// JetBrains Darcula dark theme color constants.
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
pub const background = Color.rgb(0x2B, 0x2B, 0x2B); // #2B2B2B - main content area
pub const toolbar = Color.rgb(0x3C, 0x3F, 0x41); // #3C3F41 - toolbar/header
pub const sidebar = Color.rgb(0x3C, 0x3F, 0x41); // #3C3F41 - sidebar
pub const border = Color.rgb(0x32, 0x32, 0x32); // #323232 - borders/dividers

// Selection and hover
pub const selection = Color.rgb(0x21, 0x42, 0x83); // #214283 - selected row
pub const hover = Color.rgb(0x35, 0x37, 0x39); // #353739 - hover highlight
pub const focus_border = Color.rgb(0x46, 0x6D, 0x94); // #466D94 - focused element border

// Text
pub const text_primary = Color.rgb(0xA9, 0xB7, 0xC6); // #A9B7C6 - primary text
pub const text_secondary = Color.rgb(0x80, 0x80, 0x80); // #808080 - secondary/dimmed text
pub const text_bright = Color.rgb(0xCC, 0xCC, 0xCC); // #CCCCCC - bright/emphasized text
pub const text_link = Color.rgb(0x58, 0x9D, 0xF6); // #589DF6 - link/accent text

// Syntax/category colors (for file type indicators)
pub const color_directory = Color.rgb(0xCC, 0x78, 0x32); // #CC7832 - orange, directories
pub const color_code = Color.rgb(0x6A, 0x87, 0x59); // #6A8759 - green, code files
pub const color_images = Color.rgb(0x68, 0x97, 0xBB); // #6897BB - blue, images
pub const color_documents = Color.rgb(0xFE, 0xC5, 0x6A); // #FEC56A - yellow, documents
pub const color_audio = Color.rgb(0x9B, 0x76, 0xAD); // #9B76AD - purple, audio
pub const color_video = Color.rgb(0xE8, 0x73, 0x70); // #E87370 - red, video
pub const color_archives = Color.rgb(0x80, 0x80, 0x80); // #808080 - gray, archives
pub const color_text = Color.rgb(0xA9, 0xB7, 0xC6); // #A9B7C6 - default, text

// Button/control
pub const button_bg = Color.rgb(0x4C, 0x52, 0x54); // #4C5254
pub const button_hover = Color.rgb(0x5C, 0x62, 0x64); // #5C6264
pub const button_pressed = Color.rgb(0x38, 0x3B, 0x3D); // #383B3D

// Scrollbar
pub const scrollbar_track = Color.rgb(0x2B, 0x2B, 0x2B); // same as background
pub const scrollbar_thumb = Color.rgb(0x5A, 0x5A, 0x5A); // #5A5A5A

// Window
pub const window_min_width: f64 = 800;
pub const window_min_height: f64 = 600;
pub const window_default_width: f64 = 1100;
pub const window_default_height: f64 = 700;
pub const sidebar_width: f64 = 220;
