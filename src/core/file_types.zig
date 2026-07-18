const std = @import("std");
const types = @import("types.zig");
const FileCategory = types.FileCategory;

/// Maps file extensions (lowercase, without dot) to FileCategory.
/// Uses a comptime-generated perfect hash map for O(1) lookup.
pub const extension_map = std.StaticStringMap(FileCategory).initComptime(.{
    // Images
    .{ "png", .images },
    .{ "jpg", .images },
    .{ "jpeg", .images },
    .{ "gif", .images },
    .{ "webp", .images },
    .{ "svg", .images },
    .{ "heif", .images },
    .{ "heic", .images },
    .{ "bmp", .images },
    .{ "ico", .images },
    .{ "tiff", .images },
    .{ "tif", .images },
    .{ "psd", .images },
    .{ "raw", .images },

    // Text
    .{ "txt", .text },
    .{ "md", .text },
    .{ "rst", .text },
    .{ "log", .text },
    .{ "org", .text },
    .{ "tex", .text },
    .{ "nfo", .text },

    // Documents
    .{ "pdf", .documents },
    .{ "doc", .documents },
    .{ "docx", .documents },
    .{ "odt", .documents },
    .{ "rtf", .documents },
    .{ "pages", .documents },
    .{ "epub", .documents },

    // Spreadsheets
    .{ "xls", .spreadsheets },
    .{ "xlsx", .spreadsheets },
    .{ "csv", .spreadsheets },
    .{ "ods", .spreadsheets },
    .{ "numbers", .spreadsheets },
    .{ "tsv", .spreadsheets },

    // Audio
    .{ "mp3", .audio },
    .{ "wav", .audio },
    .{ "aac", .audio },
    .{ "flac", .audio },
    .{ "ogg", .audio },
    .{ "m4a", .audio },
    .{ "wma", .audio },
    .{ "aiff", .audio },
    .{ "opus", .audio },
    .{ "mid", .audio },
    .{ "midi", .audio },

    // Video
    .{ "mp4", .video },
    .{ "avi", .video },
    .{ "mov", .video },
    .{ "mkv", .video },
    .{ "flv", .video },
    .{ "wmv", .video },
    .{ "webm", .video },
    .{ "m4v", .video },
    .{ "mpg", .video },
    .{ "mpeg", .video },

    // Code
    .{ "zig", .code },
    .{ "sema", .code },
    .{ "rs", .code },
    .{ "py", .code },
    .{ "js", .code },
    .{ "ts", .code },
    .{ "jsx", .code },
    .{ "tsx", .code },
    .{ "go", .code },
    .{ "c", .code },
    .{ "h", .code },
    .{ "cpp", .code },
    .{ "hpp", .code },
    .{ "cc", .code },
    .{ "java", .code },
    .{ "rb", .code },
    .{ "swift", .code },
    .{ "kt", .code },
    .{ "scala", .code },
    .{ "html", .code },
    .{ "css", .code },
    .{ "scss", .code },
    .{ "less", .code },
    .{ "json", .code },
    .{ "yaml", .code },
    .{ "yml", .code },
    .{ "toml", .code },
    .{ "xml", .code },
    .{ "sh", .code },
    .{ "bash", .code },
    .{ "zsh", .code },
    .{ "fish", .code },
    .{ "ps1", .code },
    .{ "lua", .code },
    .{ "php", .code },
    .{ "pl", .code },
    .{ "r", .code },
    .{ "sql", .code },
    .{ "graphql", .code },
    .{ "proto", .code },
    .{ "vue", .code },
    .{ "svelte", .code },
    .{ "elm", .code },
    .{ "ex", .code },
    .{ "exs", .code },
    .{ "erl", .code },
    .{ "hs", .code },
    .{ "ml", .code },
    .{ "clj", .code },
    .{ "dart", .code },
    .{ "nim", .code },
    .{ "v", .code },
    .{ "asm", .code },
    .{ "wasm", .code },
    .{ "makefile", .code },
    .{ "cmake", .code },
    .{ "dockerfile", .code },

    // Archives
    .{ "zip", .archives },
    .{ "tar", .archives },
    .{ "gz", .archives },
    .{ "bz2", .archives },
    .{ "xz", .archives },
    .{ "7z", .archives },
    .{ "rar", .archives },
    .{ "zst", .archives },
    .{ "lz4", .archives },
    .{ "dmg", .archives },
    .{ "iso", .archives },
    .{ "jar", .archives },
    .{ "deb", .archives },
    .{ "rpm", .archives },
});

/// Returns the FileCategory for a given filename.
/// Extracts the extension and looks it up in the map.
pub fn categorize(filename: []const u8) FileCategory {
    const ext = extractExtension(filename) orelse return .uncategorized;
    // Extensions in the map are already lowercase; we need to lowercase the input.
    var lower_buf: [32]u8 = undefined;
    if (ext.len > lower_buf.len) return .uncategorized;
    for (ext, 0..) |ch, i| {
        lower_buf[i] = std.ascii.toLower(ch);
    }
    return extension_map.get(lower_buf[0..ext.len]) orelse .uncategorized;
}

/// Extracts the file extension without the dot.
/// Returns null for dotfiles without further extension (e.g., ".gitignore")
/// and for files with no extension.
pub fn extractExtension(filename: []const u8) ?[]const u8 {
    if (filename.len == 0) return null;

    // Find the last dot
    var i: usize = filename.len;
    while (i > 0) {
        i -= 1;
        if (filename[i] == '.') {
            // Dot at start means dotfile, not an extension
            if (i == 0) return null;
            const ext = filename[i + 1 ..];
            if (ext.len == 0) return null;
            return ext;
        }
    }
    return null;
}

// Tests
test "categorize common extensions" {
    const expect = std.testing.expect;
    try expect(categorize("photo.png") == .images);
    try expect(categorize("photo.JPG") == .images);
    try expect(categorize("readme.md") == .text);
    try expect(categorize("report.pdf") == .documents);
    try expect(categorize("data.csv") == .spreadsheets);
    try expect(categorize("song.mp3") == .audio);
    try expect(categorize("movie.mp4") == .video);
    try expect(categorize("main.zig") == .code);
    try expect(categorize("program.sema") == .code);
    try expect(categorize("backup.tar") == .archives);
    try expect(categorize("backup.gz") == .archives);
}

test "categorize no extension" {
    const expect = std.testing.expect;
    try expect(categorize("Makefile") == .uncategorized);
    try expect(categorize("LICENSE") == .uncategorized);
    try expect(categorize("") == .uncategorized);
}

test "categorize dotfiles" {
    const expect = std.testing.expect;
    try expect(categorize(".gitignore") == .uncategorized);
    try expect(categorize(".env") == .uncategorized);
    try expect(categorize(".bashrc") == .uncategorized);
}

test "categorize compound extensions" {
    const expect = std.testing.expect;
    // .tar.gz → last extension is "gz" → archives
    try expect(categorize("backup.tar.gz") == .archives);
    try expect(categorize("data.json.bak") == .uncategorized);
}

test "extractExtension" {
    const expect = std.testing.expect;
    try expect(std.mem.eql(u8, extractExtension("foo.txt").?, "txt"));
    try expect(std.mem.eql(u8, extractExtension("foo.tar.gz").?, "gz"));
    try expect(extractExtension(".gitignore") == null);
    try expect(extractExtension("noext") == null);
    try expect(extractExtension("") == null);
    try expect(extractExtension("trailing.") == null);
}
