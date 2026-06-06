// Test root that imports all modules with embedded tests.
comptime {
    // Core
    _ = @import("core/types.zig");
    _ = @import("core/file_types.zig");
    _ = @import("core/fake_fs.zig");
    _ = @import("core/navigator.zig");
    _ = @import("core/folder_colors.zig");
    _ = @import("core/pins.zig");
    _ = @import("core/filters.zig");
    _ = @import("core/query_parser.zig");
    _ = @import("core/filter_store.zig");
    _ = @import("core/humanize.zig");
    _ = @import("config/config.zig");
    _ = @import("config/user_config.zig");

    // Index
    _ = @import("index/format.zig");
    _ = @import("index/bitmap.zig");
    _ = @import("index/reader.zig");
    _ = @import("index/search.zig");
    _ = @import("index/builder.zig");

    // C ABI
    _ = @import("capi/zest_core.zig");
}
