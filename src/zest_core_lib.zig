// Library entry point for libzest-core.a.
// All exports live in capi/zest_core.zig; this wrapper ensures the module
// root is `src/` so that relative imports (`../index/`, `../core/`) resolve.
comptime {
    _ = @import("capi/zest_core.zig");
}
