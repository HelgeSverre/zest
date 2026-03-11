// Test root that imports all modules with embedded tests.
comptime {
    // Core
    _ = @import("core/types.zig");
    _ = @import("core/file_types.zig");
    _ = @import("core/fake_fs.zig");
    _ = @import("core/navigator.zig");
    _ = @import("core/pins.zig");
    _ = @import("config/config.zig");

    // Index
    _ = @import("index/format.zig");
    _ = @import("index/bitmap.zig");
    _ = @import("index/reader.zig");
    _ = @import("index/search.zig");
}
