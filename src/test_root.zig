// Test root that imports all modules with embedded tests.
comptime {
    // Core
    _ = @import("core/types.zig");
    _ = @import("core/file_types.zig");
    _ = @import("core/filters.zig");
    _ = @import("core/humanize.zig");
    _ = @import("config/config.zig");
    _ = @import("config/user_config.zig");

    // Index
    _ = @import("index/format.zig");
    _ = @import("index/bulk_scan.zig");
    _ = @import("index/bitmap.zig");
    _ = @import("index/reader.zig");
    _ = @import("index/subtree.zig");
    _ = @import("index/search.zig");
    _ = @import("index/builder.zig");
    _ = @import("index/startup.zig");

    // C ABI
    _ = @import("capi/zest_core.zig");
}
