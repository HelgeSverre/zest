# CLAUDE.md

## Project Overview

**Zest** is a minimal, fast Finder replacement for macOS. Hybrid architecture:

- **`Zest.app`** — Swift/AppKit GUI (`Sources/Zest/`), links `libzest-core.a`.
- **`libzest-core.a`** — Zig search engine behind a C ABI (`src/capi/zest_core.zig`); the Swift app mmaps the index and hands the bytes to `zest_open`.
- **`zest-indexer`** — Zig background daemon (`src/indexer_main.zig`): walks `$HOME` with parallel `getattrlistbulk`, writes the index, watches FSEvents.

There is also a **legacy pure-Zig GUI** (`src/main.zig`, `src/app.zig`, `src/ui/`, plus `src/core/{async_search,dispatch,navigator,user_state,fs_provider,real_fs,fake_fs}.zig` and `src/index/session.zig`) that the Swift app superseded. It still builds but is scheduled for archival — don't extend it (see docs/ROADMAP.md Phase D).

## Build & Test

```sh
just build          # zig build + ReleaseFast core lib + swift build
just test           # zig build test + swift test
just run            # build + swift run Zest
just index          # build indexer (ReleaseFast) + full scan of ~
just bench-capi     # benchmark the engine against the real index
```

**Always leave `zig-out/lib/libzest-core.a` in ReleaseFast** — Package.swift links whatever is there, and a Debug engine is ~19× slower (an 82-second one-char query). A bare `zig build` or `zig build test` installs a Debug lib; follow it with `zig build core -Doptimize=ReleaseFast` (the justfile recipes do this).

## Architecture

See `docs/ARCHITECTURE.md` (accurate, kept current) and `docs/ROADMAP.md` (diagnosis, benchmarks, phased plan). Key points:

- **Index** — custom mmap'd columnar binary at `~/Library/Application Support/zest/index.zst` (~538 MB for 5.5M entries): names (original + lowercase blobs), prefix-deduped dir table + parent ids, metadata arrays, per-category bitmaps, per-folder histogram + ext-breakdown columns.
- **Search** (`src/index/search.zig`) — substring scan over the lowercase name blob (two-anchor check + memcmp); entry indices recovered by binary search are *monotonic in blob position* (the O(1) dedup relies on this). Filter-only queries scan the parent-id column; depth-1 listings resolve the scope dir id once.
- **Swift UI flow** — `AppCoordinator` owns path/scope/filter/sort state and a per-change-tick result cache; `onChange` (single closure, assigned once in `RootViewController`) refreshes toolbar/filter bar/browser/sidebar/status bar. Queries are currently synchronous on the main thread (moving off-main is roadmap A5).
- **Daemon** — writes `.tmp` then atomic `rename()`. The Swift app does NOT yet hot-reload the index (roadmap A7); the old 5s stat-poll lives only in the legacy `session.zig`.

## Code Conventions

- Zig 0.16.0. Filesystem/clock/env access in the *binaries* goes through the global `Io` handle in `core/runtime.zig` (set once in `main` from `std.process.Init`). The C-ABI lib (`capi/`) deliberately has **no** `Io` and no global state — pure CPU over caller-owned bytes.
- FFI contract: `ZestRow` strings borrow into the mmap; Swift copies them immediately in `ZestCore.query`. Never hold Zig-side pointers in Swift beyond the call.
- Swift: 4-space indent (swift-format config in repo), AppKit (no SwiftUI), Auto Layout with explicit constraints, Theme.* constants for all colors.
- Tests: Zig tests embedded in source files, rooted at `src/test_root.zig`; Swift tests in `Sources/ZestTests`. Engine changes must keep `zest_query` result counts stable (benchmark harness prints them — compare before/after).
- Perf changes: run `just bench-capi` before and after; medians over 7 samples; the table lives in docs/ROADMAP.md.

## Project Structure

```
Sources/Zest/          — Swift app: App/ (coordinator, delegate), Shell/ (toolbar,
                         search, breadcrumb, filter bar, status bar), Browser/
                         (file list), Sidebar/, Core/ (ZestCore FFI wrapper), Design/
Sources/CZestCore/     — C header module for the Zig lib
src/capi/              — C ABI (zest_open/query/histogram/ext_breakdown)
src/index/             — format, builder, bulk_scan, reader, search, subtree,
                         bitmap, fsevents, daemon (+ legacy session.zig)
src/core/              — types, file_types, filters, humanize, config, runtime
                         (+ legacy fs abstraction files)
src/ui/, src/app.zig, src/main.zig — legacy Zig GUI (do not extend)
benchmarks/            — bench_capi.zig (engine regression harness)
docs/                  — ARCHITECTURE.md, ROADMAP.md, archive/ (superseded docs)
```
