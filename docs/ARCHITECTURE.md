# Zest — Architecture

A minimal, fast Finder replacement for macOS. Four artifacts (a daemon, a
read-only CLI, a static lib, and a GUI app) cooperate through a single shared
file: the columnar index on disk.

> **One-line summary**: `zest-indexer` (Zig daemon) walks `~/` and writes a
> mmap-friendly binary index; `Zest.app` (Swift/AppKit) mmaps the same file and
> calls `libzest-core.a` (Zig, C ABI) to search it; `zest-query` mmaps it from
> the terminal.

## The artifacts

| Artifact         | Type         | Source root             | What it does                                                                     |
| ---------------- | ------------ | ----------------------- | -------------------------------------------------------------------------------- |
| `zest-indexer`   | CLI / daemon | `src/indexer_main.zig`  | Walks the filesystem, writes the index, watches for changes, launchd control.    |
| `zest-query`     | CLI          | `src/query_main.zig`    | Read-only search over the index from a shell (TSV output; see `docs/ZEST-QUERY.md`). |
| `libzest-core.a` | Static lib   | `src/zest_core_lib.zig` | Pure-CPU search engine exposed as a C ABI (reader + query + bitmap filter).      |
| `Zest.app`       | Swift GUI    | `Sources/Zest/...`      | Native AppKit window; links `libzest-core.a`; mmaps the index.                   |

All three Zig targets are declared in `build.zig` (`zig build core`,
`zig build indexer`, `zig build query`, `zig build test`). `build.zig` also
reads `release.json` into a `build_info` option module so `--version` output is
stamped from one source of truth, and reserves `headerpad_size = 0x1000` in both
executables so `codesign` cannot overwrite x86_64 code.

The packaged app (`scripts/package.sh`, `just app-package`) is a Universal
bundle that carries the two Zig binaries as helpers:

```
Zest.app/Contents/
├── MacOS/Zest
├── Helpers/zest-indexer                       ← bundled daemon
├── Helpers/zest-query                         ← bundled CLI
├── Library/LaunchAgents/dev.zest.app.indexer.plist
├── Resources/AppIcon.icns, ThirdPartyNotices.txt, "Installation and Removal.txt"
└── Info.plist                                 ← from macos/Info.plist
```

Signing, notarization, the PKG, and Homebrew are described in
`docs/RELEASE.md`; this document covers only how the pieces fit at runtime.

The legacy pure-Zig GUI (`src/main.zig`, `src/app.zig`, `src/ui/`, and related
Zig files) has been deleted. The Swift app is the only GUI.

## Roles of the two languages

### Zig — the engine

- The whole "is this file big / new / a PDF / named report" decision is Zig.
- The index format, the bulk scanner, the FSEvents watcher, the SIMD substring
  search, the bitmap intersection, and the `kind:` / `ext:` / `size:` /
  `date:` / `cat:` / `path:` qualifier parser (`core/filters.zig`) are all Zig.
- The daemon is a small, focused process. It has no UI, no networking, no
  shared state beyond three files in the app-support dir (the index, a
  progress JSON, and a re-index request token).
- The static library has *no* `main` and *no* `Io` handle — it borrows caller-
  provided bytes (a Swift mmap) for the lifetime of the Core. The only clock it
  touches is libc `time()` for relative `date:` qualifiers.
- `src/engine.zig` re-exports the pure engine modules as one named module so
  roots outside `src/` (the synthetic benchmark) can import them.

### Swift — the shell

- Window chrome, AppKit wiring, keyboard shortcuts, table view, sidebar tree,
  context menus, file preview, the "Open in Finder" / "Open in Terminal"
  calls, pins / folder colors / saved filters persistence, and management of
  the bundled indexer service (SMAppService, Full Disk Access onboarding).
- Nothing search-shaped is in Swift. The UI never iterates an index — it
  asks `ZestCore.query(...)` and gets back copied `Row` values.
- A single `ZestCore` instance owns the mmap for the index file and the Core
  handle from `zest_open`. Every other component goes through it.
- The app is AppKit with explicit Auto Layout. Two surfaces are SwiftUI hosted
  in `NSHostingView`: the Full Disk Access onboarding window
  (`IndexerOnboardingView`) and the first-index progress overlay
  (`FirstIndexProgressView`, plus the status bar's `IndexProgressBar`).

## The shared file: `index.zst`

The indexer, the CLI, and the GUI agree on a single file:

```
~/Library/Application Support/zest/index.zst
```

It's a custom binary format (`src/index/format.zig`, magic `"ZESTINDX"`,
80-byte header, all little-endian) with a columnar layout:

```
┌────────────────────── HEADER (80 bytes) ──────────────────────┐
│ u64 magic │ u32 version │ u32 pad │ u64 num_entries              │
│ u64 created_at │ u64 names_off │ u64 paths_off │ u64 meta_off    │
│ u64 bitmap_off │ u64 histogram_off │ u64 ext_breakdown_off       │
├────────────────────── NAMES column ───────────────────────────┤
│ u32 offsets[num] │ u16 lengths[num] │ u32 blob_len │ blob        │
│                                     │ u32 lower_len │ lower       │
├────────────────────── PATHS column ───────────────────────────┤
│ u32 parent_id[num]  (entry → dir table)                         │
│ u32 dir_count                                                    │
│ u32 dir_offsets[dir_count] │ u32 dir_blob_len │ dir_blob        │
├────────────────────── METADATA column ────────────────────────┤
│ u64 size[num] │ i64 mtime[num] │ u8 kind[num] │ u8 cat[num]     │
│   size = allocated bytes (size on disk, v6); directory entries' │
│   size = recursive subtree total rolled up at build time (v4)   │
├────────────────────── BITMAPS ────────────────────────────────┤
│ u32 num_bitmaps                                                  │
│ for each: u8 cat │ u32 count │ u32 indices[count] (sorted)       │
├────────────────────── HISTOGRAM (v2) ─────────────────────────┤
│ u32[9] per directory, dir-table order (per-folder × category)   │
├────────────────────── EXT BREAKDOWN (v3) ─────────────────────┤
│ for each (dir, cat): u16 num_exts ≤ 32,                         │
│   then num_exts × (u8 len ≤ 15, u8 bytes[len], u32 count)       │
│   sorted by count desc                                           │
└─────────────────────────────────────────────────────────────────┘
```

Current `VERSION` is 7; the reader accepts `MIN_READ_VERSION` 6 and up. The
version history is in the doc comment at the top of `format.zig` (v2 histogram
column, v3 ext-breakdown column, v4 recursive folder sizes, v5 `.sema` → Code,
v6 allocated sizes, v7 UTF-8 case-folded lowercase blob). Layout-compatible
bumps exist purely to force a reindex when the *semantics* of a column change.

Why columnar:

- The lowercased-name blob is one contiguous `[]u8` that SIMD substring search
  can scan in a single pass. The row index is recovered by binary search
  through the `u32` offsets array. The scan compares two `@Vector(N, u8)`
  registers per step — the bytes at the candidate position against the query's
  first character, and the bytes `qlen - 1` further on against its last — and
  ANDs the masks, so one instruction rejects 16 positions on Apple Silicon (32
  under AVX2) and only survivors reach the full `memcmp`. `N` comes from
  `std.simd.suggestVectorLength`, so there are no per-architecture code paths.
- The blob is UTF-8 case-*folded*, not ASCII-lowercased (`core/casefold.zig`,
  table generated by `Tools/generate_casefold.py` into `casefold_data.zig`),
  with the same fold applied to the query. Folding is length-preserving by
  construction, which is what lets one `(offset, length)` pair address a name
  in both blobs. The v7 reader also accepts layout-compatible v6 indexes and
  uses their ASCII query fold during a rolling upgrade; Unicode matching turns
  on when the daemon publishes the next v7 index.
- The `u8 kind` / `u8 category` arrays plus the per-category sorted `u32` index
  lists let the search engine eliminate rows that don't match a `cat:code` /
  `ext:pdf` filter in O(1) per candidate (binary search on a sorted bitmap).
- Directory paths are stored once in a prefix-deduped table; each entry holds
  just the 4-byte `parent_id` index. Filter-only queries at depth 1 resolve the
  scope to one dir id (`IndexReader.findDirId`) and compare that `u32` per
  entry instead of string-matching paths; unlimited-depth subtree scopes mark
  descendant dirs once (O(D) over the dir table) and test one byte per entry.
- The histogram and ext-breakdown columns make the sidebar's per-folder
  category counts an O(1) block read (`IndexReader.getFolderHistogram`,
  `getFolderExtBreakdown`); subtree scopes merge over the dir table in
  `subtree.zig` (O(D), not O(n)).

## The C ABI surface

`libzest-core.a` exports 14 functions from `src/capi/zest_core.zig`, declared
for Swift in `Sources/CZestCore/include/zest_core.h`:

- lifecycle: `zest_open` (borrow caller bytes), `zest_close`, `zest_count`
- queries: `zest_query`, `zest_query_cancellable`, `zest_query_count`,
  `zest_query_row`, `zest_query_free`
- cancellation: `zest_cancel_token_create` / `_destroy` / `_cancel`
- sidebar: `zest_histogram` (9 per-category counts for a scope),
  `zest_ext_breakdown` (top-N extensions for a scope × category, cap 32)
- `zest_casefold_utf8` (the engine's fold, so Swift's structured `ext:` filter
  canonicalizes exactly like the index)

`ZestRow` is a fixed-layout `extern struct` (name, dir_path, size, mtime, kind,
category) that Swift consumes through the Clang-imported header — the layout
cannot drift. Strings borrow into the index mmap; `ZestCore.query` copies them
to `String` before returning. `zest_query_cancellable` reports
`ZEST_QUERY_OK` / `ZEST_QUERY_ERROR` / `ZEST_QUERY_CANCELLED` through an
out-parameter; the token is one atomic word polled every 64 KiB of blob (text
scans) or every 512 entries (filter-only scans). The full per-function
reference — arguments, ownership, error semantics, threading — is in
[docs/CAPI.md](CAPI.md).

## End-to-end data flow

The full path of a search, from the kernel to a visible table row:

```
                     ┌─────────────────┐
                     │ macOS filesystem│  ~/
                     │  (kernel)       │
                     └────────┬────────┘
                              │ getattrlistbulk (≤ 8 worker threads)
                              ▼
                     ┌─────────────────┐
                     │ bulk_scan.zig   │  per-worker scan-<id>.N (TSV shards)
                     └────────┬────────┘
                              │ read back, build columnar
                              ▼
                     ┌─────────────────┐
                     │ builder.zig     │
                     │ format.zig      │  → createFileAtomic + replace
                     └────────┬────────┘
                              │
                              ▼
       ┌──────────────────────────────────────┐
       │ ~/Library/Application Support/zest/  │ ◀──── mmap()'d by Swift (ZestCore)
       │   index.zst                          │       and by zest-query
       │   progress-daemon.json               │ ◀──── polled by the app every 1 s
       │   reindex.request                    │ ◀──── written by app / CLI, read by daemon
       └────────────────┬─────────────────────┘
                        │
                        ▼
              ┌──────────────────┐         ┌──────────────────────┐
              │ libzest-core.a   │ ◀─ FFI ─│ Zest.app (Swift)     │
              │   zest_query(…)  │         │  NSTableView + UI    │
              │   IndexReader    │         │  + AppCoordinator    │
              │   search()       │         │  + ZestCore          │
              └────────┬─────────┘         └──────────┬───────────┘
                       │                               │
                       │  ZestRow {name, dir_path,     │ FileItem (copied
                       │  size, mtime, kind, category} │ strings, lazy
                       │  — borrows mmap               │ formatting)
                       ▼                               ▼
                raw bytes  ─────────────────────►  rendered row
```

The daemon never talks to the GUI over IPC and the GUI never talks to the
daemon. They cooperate only through files in the app-support directory: the
index (atomic replace, fresh inode), the progress JSON (telemetry), and the
request token (a nudge). The app *does* control the daemon's lifecycle, but
only through launchd (`SMAppService`), never directly.

## Live updates

### Daemon side

`src/index/daemon.zig` is the daemon's main loop; the pieces it composes are
small, testable modules:

1. **Startup order** (`startup.zig`): start the FSEvents watcher *before* the
   initial scan, then enter the watch loop, so changes made during the first
   scan are not lost. A failed initial scan marks the schedule as failed and
   the loop retries with backoff.
2. **Initial scan**: parallel `getattrlistbulk` walk of `$HOME` (or the path
   argument), written to `index.zst` via `createFileAtomic` + `replace`
   (`progress.Reporter.writeIndex`, 1 MiB chunks, `fsync` before rename).
3. **FSEvents watcher** (`fsevents.zig` over the C bridge
   `fsevents_bridge.c`): one `FSEventStream` on the root with 2.0 s latency and
   `NoDefer | IgnoreSelf | WatchRoot` — directory-level events, so each path
   is a directory whose contents changed. The canonical app-support
   dir is passed to `FSEventStreamSetExclusionPaths` so the daemon's own index
   writes (and any other writer's) never schedule a rebuild; `onFSEvent` filters
   a second time through `config.shouldExcludeDescendant`, then records the
   directory in a dirty set. A callback carrying
   `UserDropped` / `KernelDropped` / `RootChanged` counts as
   `schedule.event_threshold` events on its own and forces the next rebuild
   to be a full walk.
4. **Coalesced rebuild** (`schedule.zig`): the CFRunLoop wakes every 2 s
   (`zest_run_loop_run(2.0)`, or early via `zest_run_loop_stop` once the
   pending count crosses the threshold). A rebuild is due when any of:
   `pending ≥ 1000` events; `pending > 0` and ≥ 30 s since the last success;
   ≥ 24 h since the last success (daily self-heal); an explicit request; or a
   previous failure whose retry time has passed. Failures back off
   `5 s × 2^(failures-1)`, capped at 300 s, and keep the last good index.
   **Incremental rebuild** (`incremental.zig`): an ordinary change batch does
   not walk the tree. The daemon reads the previous `index.zst` back into
   entries, relists each dirty directory with one `getattrlistbulk` call,
   drops old entries under directory children that vanished from a listing
   (deleted or renamed away), recursively scans directory children the old
   index never saw (created or renamed in), patches the relisted directories'
   own mtimes, and hands the merged entries to `writeIndex`, which re-derives
   folder sizes, histograms, and extension buckets. On a 4.1M-entry home this
   is ~0.3 s merge + ~0.9 s build + ~0.6 s write versus a 15–20 s, 60
   CPU-second walk. Explicit requests, dropped events, a failed previous
   rebuild, and the daily self-heal still take the full walk; so does a batch
   touching more than `max(64, dirs/20)` directories or more than 256
   vanished/new subtrees (`error.TooManyChanges`).
5. **Re-index requests**: `zest-indexer reindex` (CLI) or the app's *Re-index
   Now* writes a token to `reindex.request`. The daemon reads the first 16
   bytes each tick and rebuilds when the token differs from the one it last
   acknowledged; the file is never deleted, so a request that lands mid-scan
   survives that scan.
6. **Progress telemetry** (`progress.zig`): every scan writes
   `progress-daemon.json` (daemon) or `progress-manual-<pid>.json` (one-shot
   `--full-scan`) with `phase` ∈ scanning / building / writing / published /
   failed, entry count, current path, bytes written / total, and `pid`. A
   heartbeat thread re-emits it every second; writes are atomic and `0600`.
   Telemetry failures never fail a build.
7. **launchd hosting**, two flavours:
   - *Packaged app*: `Zest.app/Contents/Library/LaunchAgents/dev.zest.app.indexer.plist`
     (`BundleProgram` → `Contents/Helpers/zest-indexer`, `KeepAlive`,
     `ProcessType=Background`, `LowPriorityIO`, `ThrottleInterval` 30). macOS
     owns registration via `SMAppService`; the daemon binary never leaves the
     bundle.
   - *Development*: `service.zig` implements `zest-indexer install |
     prepare-install | uninstall | status | start | stop | restart | reindex |
     probe-access`. `install` copies the binary to
     `~/Library/Application Support/zest/bin/zest-indexer`, writes
     `~/Library/LaunchAgents/dev.zest.indexer.plist` (label `dev.zest.indexer`,
     stderr to `daemon.log`), and `launchctl bootstrap`s it into `gui/<uid>`.
     `just daemon-install` / `just daemon-uninstall` wrap this. The two labels
     differ so the packaged and development services cannot take over each
     other's jobs; do not run both.

### App side

- **Index hot-reload**: a 5-second `Timer` (`AppCoordinator.indexPollInterval`)
  calls `ZestCore.currentIdentity(of:)` to stat the index and compares inode,
  size, and mtime against the open core's `fileIdentity`. When any field
  differs (including `core == nil` because the index didn't exist at launch),
  it opens a new `ZestCore` and swaps. Rows are copied at the FFI boundary, so
  dropping the old core is safe; ARC unmaps it. `IndexProgressMonitor`'s
  1-second tick also calls `reloadIndexIfChanged`, so a freshly published index
  is picked up within a second of the daemon reporting `published`.
- **Progress display**: `IndexProgressMonitor` reads the newest valid
  `progress-*.json` (≤ 32 KiB, regular file, `updated_at` within
  `-5…+12 s` of now, owning `pid` alive) once per second on a utility queue.
  `IndexProgressModel` turns that plus "is a usable core loaded" into a phase
  (idle / scanning / building / writing / loading / ready / interrupted). On
  first run (no index at launch) `FirstIndexProgressView` covers the window
  until the index is loaded and searchable; afterwards the status bar shows a
  compact "Updating index …" strip. Completion is only ever inferred from a
  loaded, queryable core, never from the JSON.
- **Bundled indexer lifecycle** (`App/Indexer*.swift`,
  `BundledIndexerService.swift`, `ReleaseInstallation.swift`):
  - `ReleaseInstallation.isPackaged` (bundle URL ends in `.app`) selects the
    control path. Packaged builds use `BundledIndexerService`
    (`SMAppService.agent(plistName: "dev.zest.app.indexer.plist")`, label
    `dev.zest.app.indexer`); `swift run` builds use
    `CommandLineIndexerService`, which shells out to a located
    `zest-indexer` (`zig-out/bin/zest-indexer` up to 8 directories above the
    executable, `Contents/Resources`, or the dev install path) and drives the
    legacy `service.zig` commands.
  - `IndexerMenuController` owns the **Index** menu. Every process operation
    runs on the serial `dev.zest.indexer-control` queue with a generation
    guard; menu state is refreshed on open and after each action. States are
    `not_installed` / `stopped` / `running` / `waiting` / `requiresApproval`
    (`IndexerState`); liveness of an `.enabled` registration is checked with
    `launchctl print gui/<uid>/dev.zest.app.indexer`. A fresh launch only
    *reads* state — it never registers, migrates, or starts a scan.
  - `ReleaseInstallation.requireInstalledApp()` refuses to register from a
    bundle that is not in `/Applications` or `~/Applications` (DMG or
    translocated copies).
  - **Full Disk Access flow**: *Set Up Indexer…* / *Set Up Full Disk Access…*
    open `IndexerAccessSetupController` (a SwiftUI three-step window: welcome →
    open System Settings → verify). Every 2 s it runs
    `IndexerAccessVerifier.check`, which bootstraps a throwaway launchd job
    (`dev.zest.access.<uuid>`) that executes the *installed* helper with
    `probe-access` and waits up to 4 s for its stdout. The helper
    (`index/access.zig`) tries to iterate `~/Library/Safari`, `~/Library/Mail`,
    or `~/Library/Messages` and prints `verified` / `denied` / `unavailable`.
    Going through launchd means the *helper's* TCC grant is tested, not
    Zest's or Terminal's. *Done* requires `verified`; *Skip* starts indexing
    anyway after a confirmation. Finishing runs `install` (SMAppService
    `register`, then `indexerSetupCompleted` in `UserDefaults`) or `start`.
  - If macOS answers `.requiresApproval`, the app explains and opens *Login
    Items* (`SMAppService.openSystemSettingsLoginItems()`); background
    approval and Full Disk Access are separate permissions.
  - `stop` / `uninstall` call `unregister` and then poll `launchctl print`
    (up to 30 s) until the job is confirmed gone before any re-register.
  - `Zest --indexer-status` runs the same state check without a GUI, for
    release verification (`scripts/verify-release.mjs`).

## Threading model

- **Indexer (daemon)**: 1 process. The main thread runs the CFRunLoop that
  hosts the FSEvents stream and the 2-second schedule tick. A build spawns
  `min(cpu_count, 8)` scan workers (`bulk_scan.max_scan_threads = 8`, the
  measured sweet spot on a 12-core M-series machine — 12 workers regressed a
  warm scan from 22 s to 57 s) plus one progress heartbeat thread. Workers
  pull directories from a shared queue and stream TSV into their own
  `scan-<id>.N` shard; only one worker per second samples a "current path" for
  telemetry, and no worker thread writes telemetry files.
- **Search engine**: synchronous. `searchCancellable` accepts an optional
  atomic `u32` cancel flag; text scans poll it every 64 KiB of candidate
  positions, filter-only scans every 512 entries, and cancellation returns
  `error.SearchCancelled`. An already-cancelled token is honoured before any
  fast path.
- **Swift UI**: the main thread drives AppKit. Engine queries run on a serial
  `zest.query` `DispatchQueue` (`.userInitiated`) in `AppCoordinator`. Each
  change-tick cancels the previous tick's `ZestCore.CancelToken` before
  enqueuing its own, and a `queryGeneration` counter still guards delivery: the
  closure captures the generation and discards the result on main if it no
  longer matches. Results are capped at `AppCoordinator.maxResults = 2_000`
  and sorted off-main before delivery. `notifyChange` fires `onChange` twice
  per change: once immediately so observers show a loading state (stale rows
  still visible), and once when the fresh rows land. Other off-main work, each
  with its own generation guard: the sidebar histogram / ext-breakdown
  (`CategorySection`, `DispatchQueue.global(qos: .userInitiated)`), preview
  loading + highlighting (`dev.zest.preview-content`), indexer control
  (`dev.zest.indexer-control`), Full Disk Access polling
  (`dev.zest.access-check`), and progress-file reads
  (`dev.zest.progress-reader`).

## Swift UI component map

```
RootViewController                         (owns lifetimes; assigns coordinator.onChange once)
├── ToolbarView (56pt)                     back/forward/up · Breadcrumb · SearchField · "Saved ▾"
├── FilterBarView (42pt)                   ScopeControl (folder/subfolders/everywhere) · count · sort
├── NSSplitViewController
│   ├── SidebarViewController (190–260pt)  PINNED rows · CategorySection (histogram + ext drill-down)
│   └── BrowserViewController              NSTableView: name/size/modified/kind/ext, 34pt browse / 48pt search rows
├── StatusBarView (28pt)                   "N files indexed" · selection summary · "updated …" · progress strip
├── SavedFiltersCard                       overlay: apply / save current / manage
├── SavedFiltersDialog                     overlay scrim: CRUD over UserState.filters
├── FilePreviewOverlay                     overlay scrim: Markdown / Sema / JSON preview
└── NSHostingView<FirstIndexProgressView>  first-run overlay until the index is searchable
```

- **Coordinator / onChange flow**: `AppCoordinator` is the single source of
  truth for `currentPath`, back/forward stacks, the structured `Filter`
  (`category`, `extensions`, `text` — round-trips losslessly to the
  `cat:<k> ext:<e> <text>` string the Zig parser consumes), `scope`,
  `sortColumn` / `sortAscending` / `foldersOnTop`, and the per-tick result
  cache. `RootViewController` assigns `onChange` once; it refreshes browser,
  toolbar, filter bar, sidebar, status bar, and the progress model. Sort
  changes re-sort the cached rows without an engine round-trip unless a query
  is in flight. `commitSearch` auto-promotes `.folder` scope to `.subfolders`
  when text is present so typing searches the subtree.
- **Sidebar**: `CategorySection` calls `histogram(scope:maxDepth:)` and
  `extBreakdown(...)` for the coordinator's `(scopeRoot, scopeDepth)`; the
  result is cached and recomputed only when that context changes. Clicking a
  category sets `filter.category`; clicking an extension sets
  `cat:<k> ext:<e>`; ⌘/⌃-click toggles extensions in an OR-set
  (`SidebarViewController.extClickResult` is the pure decision function).
  Pins come from `UserState`.
- **Filter bar**: scope segmented control, item/result count (renders
  `2,000+` when `resultsCapped`), and the sort menu.
- **Saved filters**: `UserState.SavedFilter {name, query}` persisted in
  `filters.json`. The card (280pt, anchored under the toolbar's Saved button)
  applies one (`applySavedFilter` sets the query and bumps a `.folder` scope to
  `.subfolders`); the dialog adds/edits/removes.
- **File preview**: Space on a selected row (or Esc / click-outside to close).
  `PreviewRequest.route` sends `.md`/`.markdown`, `.sema`, and `.json` regular
  files to the in-window `FilePreviewOverlay` and everything else to
  `QLPreviewPanel` (Quick Look). `PreviewState.reduce` is a pure reducer over
  toggle / selection-changed / close events, so an open preview follows
  Up/Down selection. `PreviewContentLoader` reads the file off-main
  (`maxPreviewBytes` 20 MiB, highlighted only when ≤ `maxHighlightedBytes`
  5 MiB) and `TreeSitterHighlighter` colours it with tree-sitter
  (`swift-tree-sitter` 0.25.0, `tree-sitter-json` 0.24.8,
  `tree-sitter-markdown` 0.5.3 block + inline, and the vendored Sema grammar in
  `Vendor/TreeSitterSema`). The `.scm` highlight queries in
  `Vendor/HighlightQueries` and `Vendor/TreeSitterSema/queries` are embedded at
  build time by the `EmbedHighlightQueriesPlugin` SwiftPM build-tool plugin,
  which runs `Tools/EmbedHighlightQueriesTool` to generate
  `EmbeddedHighlightQueries.generated.swift`. Capture names map to
  `Theme.syntax*` colours.
- **Persistence** (`Core/UserState.swift`, all in the app-support dir):
  `pins.json`, `folder_colors.json`, `filters.json`, `prefs.json`
  (`foldersOnTop`). Corrupt files are quarantined rather than overwritten.
- **Launch modes** (`App/main.swift`, parsed by `LaunchOptions`): `zest [PATH]`
  opens a window at that directory (each invocation is its own process);
  `-h`/`--help`; `-V`/`--version`; `--indexer-status` (service state, no GUI);
  `--snapshot PNG [WxH]` renders the real view hierarchy off-screen to a PNG
  (`Snapshot.swift`, default 1180×760) for headless verification.

## What lives where

```
build.zig                   ← zig targets: indexer, query, core lib, tests; build_info from release.json
Package.swift               ← SwiftPM: Zest, ZestTests, CZestCore shim, TreeSitterSema, highlight-query plugin
justfile                    ← build / lint / format / clean / dev / run / test / test-daemon /
                              bench-capi / bench-search / bench-app / index / index-open / index-wipe /
                              query-build / daemon-install / daemon-uninstall / app-package /
                              pkg-unsigned / pkg-signed / pkg-notarized / pkg-local
release.json                ← version + build number (single source of truth)
macos/                      ← Info.plist, dev.zest.app.indexer.plist, components.plist (PKG)

src/
├── indexer_main.zig        ← daemon entry; sets runtime.io, delegates to index/daemon.zig
├── query_main.zig          ← zest-query CLI: mmap index, parse qualifiers, search, sort, print TSV
├── zest_core_lib.zig       ← library entry; pulls in capi/zest_core.zig
├── engine.zig              ← named-module root re-exporting the pure engine (benchmarks)
├── test_root.zig           ← imports every module with embedded tests
├── capi/
│   └── zest_core.zig       ← C ABI surface (14 functions + ZestRow/ZestHistogram/ZestExtCount)
├── core/
│   ├── casefold.zig        ← length-preserving UTF-8 case folding (blob + query)
│   ├── casefold_data.zig   ← generated simple-fold table (Tools/generate_casefold.py)
│   ├── cli.zig             ← shared --help/--version handling for the binaries
│   ├── filters.zig         ← qualifier parser + FilterCriterion (kind/ext/size/date/cat/path)
│   ├── types.zig           ← FileKind, FileCategory (9), FileEntry
│   ├── runtime.zig         ← global Io handle + clock / file helpers (binaries only)
│   ├── humanize.zig        ← "506.9 MiB" / duration / grouped-count formatting
│   └── file_types.zig      ← extension → FileCategory via StaticStringMap
├── index/
│   ├── format.zig          ← on-disk layout (header, columns) + writeIndex
│   ├── reader.zig          ← IndexReader over mmap'd bytes (names, dirs, meta, histogram, ext breakdown)
│   ├── search.zig          ← SIMD substring + bitmap/parent-id filters + sort + cancellation
│   ├── subtree.zig         ← O(D) subtree histogram + ext-breakdown merge
│   ├── bitmap.zig          ← sorted-array bitmap for category filtering
│   ├── builder.zig         ← scan shards → columnar index
│   ├── bulk_scan.zig       ← parallel getattrlistbulk walker (8 workers)
│   ├── fsevents.zig        ← Zig wrapper over the C FSEvents bridge
│   ├── fsevents_bridge.c/h ← FSEventStream create/start/stop + run-loop helpers
│   ├── daemon.zig          ← main loop: watcher, initial scan, rebuild loop, request file
│   ├── startup.zig         ← watcher → scan → loop ordering (testable)
│   ├── schedule.zig        ← rebuild-due rules, thresholds, retry backoff
│   ├── service.zig         ← dev launchd control (install/uninstall/status/start/stop/restart/reindex)
│   ├── access.zig          ← Full Disk Access probe (probe-access)
│   └── progress.zig        ← progress-*.json reporter + heartbeat + atomic index write
└── config/
    ├── config.zig          ← app-support paths, name_excludes, path_excludes, exclusion predicates
    └── user_config.zig     ← terminal-app candidate list for "Open in Terminal"

Sources/CZestCore/          ← header-only C module (include/zest_core.h) + empty.c relink shim
Sources/Zest/
├── App/
│   ├── main.swift                      ← entry: browse / help / version / --indexer-status / --snapshot
│   ├── LaunchOptions.swift             ← argv parsing (pure, testable)
│   ├── AppDelegate.swift               ← window + main menu (Edit/View/Index/Navigation)
│   ├── AppCoordinator.swift            ← source of truth: path, Filter, scope, sort, query queue, hot-reload timer
│   ├── Snapshot.swift                  ← off-screen render to PNG
│   ├── ReleaseInstallation.swift       ← isPackaged / isInstalled / bundled helper lookup
│   ├── IndexerControl.swift            ← IndexerControl protocol + CommandLineIndexerService (dev)
│   ├── BundledIndexerService.swift     ← SMAppService registration + state for the packaged helper
│   ├── IndexerProcess.swift            ← bounded subprocess runner (timeout, output drain)
│   ├── IndexerMenuController.swift     ← Index menu: states, actions, serial control queue
│   ├── IndexerAccessSetupController.swift ← Full Disk Access onboarding window (polls verifier)
│   ├── IndexerAccessVerifier.swift     ← launchd-hosted probe-access check
│   ├── IndexerOnboardingView.swift     ← SwiftUI onboarding steps
│   └── IndexProgress.swift             ← progress-*.json snapshot, model, 1 s monitor
├── Shell/
│   ├── RootViewController.swift        ← bands + split + overlays; wires onChange
│   ├── ToolbarView.swift · Breadcrumb.swift · SearchField.swift
│   ├── FilterBarView.swift · StatusBarView.swift
│   ├── SavedFiltersCard.swift · SavedFiltersDialog.swift
│   ├── FilePreviewOverlay.swift        ← in-window text preview panel
│   ├── FirstIndexProgressView.swift    ← SwiftUI first-run progress overlay
│   └── PlaceholderBand.swift
├── Preview/
│   ├── PreviewFormat.swift             ← md/markdown, sema, json
│   ├── PreviewState.swift              ← PreviewRequest.route + PreviewState.reduce
│   ├── PreviewContentLoader.swift      ← off-main read + size limits + highlight
│   └── TreeSitterHighlighter.swift     ← tree-sitter queries → NSAttributedString
├── Sidebar/
│   └── SidebarViewController.swift     ← PINNED + CATEGORIES (histogram, ext drill-down)
├── Browser/
│   └── BrowserViewController.swift     ← FileItem, NSTableView, context menu, preview routing, Quick Look
├── Core/
│   ├── ZestCore.swift                  ← mmap + zest_open + query/histogram/extBreakdown + FileIdentity + CancelToken
│   └── UserState.swift                 ← pins.json / folder_colors.json / filters.json / prefs.json
└── Design/
    ├── Theme.swift                     ← Ink graphite tokens, accent derivation, syntax colours
    ├── Category.swift                  ← category byte → label / colour / SF Symbol
    ├── Hairline.swift · NSView+Occlusion.swift
Sources/ZestTests/          ← XCTest: unit tests + ZestCoreTests (real index) + UITests/UIHarness (headless window)

Plugins/EmbedHighlightQueriesPlugin/    ← SwiftPM build-tool plugin (runs the tool below)
Tools/EmbedHighlightQueriesTool/        ← .scm → EmbeddedHighlightQueries.generated.swift
Tools/generate_casefold.py              ← regenerates src/core/casefold_data.zig
Vendor/HighlightQueries/                ← json / markdown / markdown-inline highlight queries + licenses
Vendor/TreeSitterSema/                  ← vendored Sema grammar (parser.c, scanner.c, highlights.scm)
benchmarks/bench_capi.zig               ← real-index C ABI harness (just bench-capi)
benchmarks/bench_search.zig             ← synthetic-corpus engine harness (just bench-search)
scripts/package.sh                      ← Universal ad-hoc Zest.app (just app-package)
scripts/package-local-signed.sh         ← notarized PKG with local identities (just pkg-local)
scripts/verify-release.mjs              ← bundle checks + isolated scan/query + --indexer-status
scripts/test-daemon.mjs                 ← live FSEvents / recovery in a temp home (just test-daemon)
scripts/render-cask.mjs · publish-cask.mjs ← Homebrew tap
scripts/make-icon.swift                 ← AppIcon iconset
.github/workflows/                      ← ci (test, test-daemon, app-package), macos-pkg, release, homebrew
.github/scripts/                        ← build-test-fixture, package-macos-pkg, import-apple-signing-assets
docs/                                   ← ARCHITECTURE, TESTING, BENCHMARKS, CAPI, RELEASE, ZEST-QUERY, releases/, archive/
```

## Index file lifecycle (one rebuild)

1. **Bulk scan** — up to 8 worker threads, each pulling directories off a
   shared queue, calling `getattrlistbulk` in batches (name, object type,
   mtime, allocated size), and streaming escaped TSV lines into their own
   `scan-<id>.N` shard under `~/Library/Application Support/zest/`. Dotfiles,
   `config.name_excludes` (`.git`, `node_modules`, …) and
   `config.path_excludes` (`Library/Caches`, `Library/Logs`,
   `Library/Developer`) are skipped. Shards are deleted after the build.
2. **Builder** — reads the shards back (any order), deduplicates paths into a
   directory table, accumulates per-folder histograms and ext buckets, rolls
   directory sizes up child → parent, accumulates per-category sorted index
   lists, and writes the columnar layout into a single contiguous `[]u8`
   (`format.writeIndex`). The parsed count is validated against the scan
   count.
3. **Atomic write** — `createFileAtomic` into the app-support dir, `fsync`,
   then `replace` onto `index.zst`. The inode changes, so any process holding
   a stale mmap keeps its snapshot until it reopens. There is no in-process
   lock.
4. **Publish** — the progress file flips to `published`; the app's next
   identity check (inode/size/mtime) opens the new file and swaps cores.

## Open questions / known gaps

- **C ABI error reporting.** `zest_open` returns `null` on any malformed
  index; callers have no way to distinguish "corrupt header" from "truncated
  file" from "wrong magic". A `zest_last_error()` string or an out-param error
  code would let the UI show a useful message.
- **Case folding is length-preserving, not full Unicode.** `core/casefold.zig`
  folds only mappings that keep the UTF-8 byte length, because the lowercase
  blob is addressed by the same `(offset, length)` pairs as the original blob.
  Codepoints whose lowercase form is a different length (`İ` → `i`, `ẞ` → `ß`,
  `K` U+212A → `k`, `ſ` → `s`) are left unfolded, and there is no Unicode
  normalization — a decomposed `e` + combining acute does not match a
  precomposed `é`. Fixing either means storing a separate folded blob with its
  own offset table.
- **Cancellation is cooperative, not preemptive.** A cancelled query unwinds at
  the next poll boundary (64 KiB of blob, or 512 entries), not instantly, and
  the sidebar histogram/ext-breakdown calls have no cancel token at all — they
  are O(1)/O(D) rather than O(n), so nothing has needed one yet.
- **Scan coverage is not reported.** Permission-denied subtrees are skipped
  silently; neither the index nor the progress file records what was missed,
  so the UI cannot say "N folders unreadable". Full Disk Access verification
  covers one protected folder, not every file.
- **`zest-query` output is unescaped TSV** and cannot report index freshness
  or completeness (see `docs/ZEST-QUERY.md`).
- **Two service registration systems coexist.** The packaged
  `dev.zest.app.indexer` (SMAppService) and the development
  `dev.zest.indexer` (`service.zig` + launchctl) must not run together; setup
  migrates the legacy one explicitly but nothing prevents installing both.

## See also

- [CLAUDE.md](../CLAUDE.md) — build, test, and code conventions.
- [docs/TESTING.md](TESTING.md) — test layers, the CI fixture, and the headless UI harness.
- [docs/CAPI.md](CAPI.md) — full C ABI reference for `libzest-core.a`.
- [docs/ZEST-QUERY.md](ZEST-QUERY.md) — the `zest-query` CLI: options, output,
  agent guidance.
- [docs/RELEASE.md](RELEASE.md) — packaging, signing, notarization, Homebrew,
  install/remove flow.
- [docs/BENCHMARKS.md](BENCHMARKS.md) — engine and UI benchmark tables.
