//! Public re-exports of the pure-CPU engine modules.
//!
//! A Zig module root owns its own directory, so a root that lives outside
//! `src/` (a benchmark under `benchmarks/`, a tool under `Tools/`) cannot
//! `@import("../src/...")`. Passing this file as a named module gives those
//! roots one import surface.
//!
//! `runtime` is re-exported because `format.writeIndex` stamps a build time and
//! therefore needs the global `Io` handle; a root that uses it must call
//! `runtime.init` from `main` exactly as the binaries do. The C-ABI library
//! does not import this file and stays Io-free.
pub const casefold = @import("core/casefold.zig");
pub const runtime = @import("core/runtime.zig");
pub const filters = @import("core/filters.zig");
pub const types = @import("core/types.zig");
pub const format = @import("index/format.zig");
pub const reader = @import("index/reader.zig");
pub const search = @import("index/search.zig");
