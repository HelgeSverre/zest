# CLAUDE.md

## Project Overview

**Zest** is a minimal, fast Finder replacement for macOS. Hybrid architecture:

- **`Zest.app`** — Swift/AppKit GUI (`Sources/Zest/`), links `libzest-core.a`.
- **`libzest-core.a`** — Zig search engine behind a C ABI (`src/capi/zest_core.zig`); the Swift app mmaps the index and hands the bytes to `zest_open`.
- **`zest-indexer`** — Zig background daemon (`src/indexer_main.zig`): walks `$HOME` with parallel `getattrlistbulk`, writes the index, watches FSEvents.

The legacy pure-Zig GUI (`src/main.zig`, `src/app.zig`, `src/ui/`, and associated Zig files) has been deleted. The Swift app is the only GUI.

## Build & Test

```sh
just build          # zig build + ReleaseFast core lib + swift build
just test           # zig build test + swift test
just dev            # build + swift run Zest (Debug)
just run            # build + swift run -c release Zest
just index          # build indexer (ReleaseFast) + full scan of ~
just bench-capi     # benchmark the engine against the real index
just bench-search   # benchmark the engine against a synthetic corpus (no index needed)
```

**Always leave `zig-out/lib/libzest-core.a` in ReleaseFast** — Package.swift links whatever is there, and a Debug engine is ~19× slower (an 82-second one-char query). A bare `zig build` or `zig build test` installs a Debug lib; follow it with `zig build core -Doptimize=ReleaseFast` (the justfile recipes do this).

SwiftPM does not track the external Zig archive as an input. Use the justfile
recipes rather than invoking `swift build/test` after Zig changes; the recipes
touch the `CZestCore` shim so the current archive is always relinked.

## Indexed file discovery

When available, `zest-query 'name kind:file' --scope "$(pwd -P)" --depth all`
can quickly locate candidate files without walking the repository. It searches
indexed filenames, not contents. Verify results before edits; use `rg --files`
for current coverage and `rg` for content. Empty results can mean a stale index,
exclusions, or missing permissions, not absence. Never trigger a full scan just
to answer a discovery query. See [docs/ZEST-QUERY.md](docs/ZEST-QUERY.md).

## Architecture

See `docs/ARCHITECTURE.md` (accurate, kept current), `docs/TESTING.md`, `docs/BENCHMARKS.md`, and `docs/CAPI.md`. Key points:

- **Index** — custom mmap'd columnar binary at `~/Library/Application Support/zest/index.zst` (~407 MB for 4.1M entries): names (original + case-folded blobs, byte-parallel — folding is length-preserving, see `core/casefold.zig`), prefix-deduped dir table + parent ids, metadata arrays, per-category bitmaps, per-folder histogram + ext-breakdown columns. Since v4, directory entries' `size` is their recursive subtree total (rolled up at build time), so folder sizes display O(1) and folders participate in sort-by-size and `size:` filters.
- **Search** (`src/index/search.zig`) — substring scan over the case-folded name blob: a SIMD two-anchor filter (`@Vector`, width from `std.simd.suggestVectorLength`) rejects a whole register of positions per step, survivors go through `memcmp`; entry indices recovered by binary search are *monotonic in blob position* (the O(1) dedup relies on this). Queries take an optional cancel flag polled every 64 KiB, exposed to Swift as `zest_query_cancellable`. Filter-only queries scan the parent-id column; depth-1 listings resolve the scope dir id once.
- **Swift UI flow** — `AppCoordinator` owns path/scope/filter/sort state and a per-change-tick result cache; `onChange` (single closure, assigned once in `RootViewController`) refreshes toolbar/filter bar/browser/sidebar/status bar. Queries run off-main on a serial `queryQueue`; a `queryGeneration` counter drops stale deliveries. `notifyChange` fires `onChange` twice per change: once immediately (observers render the last-delivered stale rows while `isLoading` is true) and once when the fresh result set lands.
- **Index hot-reload** — A 5-second `Timer` in `AppCoordinator` polls the index file's inode/size/mtime (`ZestCore.FileIdentity`/`currentIdentity`). When any field differs (or `core` is nil on first tick), it opens a new `ZestCore` and swaps. Rows are copied at the FFI boundary, so dropping the old core is safe; ARC unmaps it.
- **Daemon** — writes `.tmp` then atomic `rename()`. FSEvents stream (directory-level events) uses `kFSEventStreamCreateFlagIgnoreSelf` plus an explicit exclusion path for the app-support dir (covers external writers) to prevent rebuild-treadmill loops. Ordinary change batches rebuild **incrementally** (`src/index/incremental.zig`): relist the dirty directories, splice into the previous index's entries, rescan only new subtrees, and rewrite the columns (~1.5 s on 4M entries). Requests, dropped events, failures, and the daily scan still walk the whole tree.
- **UI states** — `BrowserViewController` shows "No results" (search mode, zero rows), "Empty folder" (browse mode, zero rows), or a blank in-flight state while a query is running.

## Code Conventions

- Zig 0.16.0. Filesystem/clock/env access in the *binaries* goes through the global `Io` handle in `core/runtime.zig` (set once in `main` from `std.process.Init`). The C-ABI lib (`capi/`) deliberately has **no** `Io` and no global state — pure CPU over caller-owned bytes.
- FFI contract: `ZestRow` strings borrow into the mmap; Swift copies them immediately in `ZestCore.query`. Never hold Zig-side pointers in Swift beyond the call.
- Swift: 2-space indent (`.swift-format` in repo), AppKit for the shell; SwiftUI only for the onboarding and first-index progress views, hosted in `NSHostingView`. Auto Layout with explicit constraints, Theme.* constants for all colors.
- Tests: Zig tests embedded in source files, rooted at `src/test_root.zig`; Swift tests in `Sources/ZestTests`. Headless UI tests (`just test-ui`) drive the real window in-process via `A11y` identifiers; see `docs/TESTING.md`. Engine changes must keep `zest_query` result counts stable (benchmark harness prints them — compare before/after).
- Perf changes: run `just bench-capi` before and after; medians over 7 samples; the table lives in docs/BENCHMARKS.md.

## Project Structure

```
Sources/Zest/          — Swift app: App/ (coordinator, delegate), Shell/ (toolbar,
                         search, breadcrumb, filter bar, status bar), Browser/
                         (file list), Sidebar/, Core/ (ZestCore FFI wrapper,
                         UserState pins/folder-colors), Design/
Sources/CZestCore/     — C header module for the Zig lib
src/capi/              — C ABI (zest_open/close/count/query/query_cancellable/
                         query_count/query_row/query_free/cancel_token_*/
                         histogram/ext_breakdown/casefold_utf8)
src/index/             — format, builder, bulk_scan, reader, search, subtree,
                         bitmap, fsevents, daemon
src/core/              — types, file_types, casefold, filters, humanize, runtime
benchmarks/            — bench_capi.zig (real-index harness), bench_search.zig (synthetic)
docs/                  — ARCHITECTURE.md, TESTING.md, BENCHMARKS.md, CAPI.md, RELEASE.md, ZEST-QUERY.md, archive/ (superseded docs)
```
