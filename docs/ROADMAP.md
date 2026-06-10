# Zest — Roadmap

> Written 2026-06-09 after a full diagnostic pass: git-history review, doc audit,
> Swift + Zig code review, and programmatic benchmarks of the C ABI
> (`benchmarks/bench_capi.zig`) against the real 5.56M-entry index.
> Re-run benchmarks with `just bench-capi` after any engine change.

## Diagnosis: why the app feels broken

Measured on the real index (538 MB, 5,562,800 entries), Apple Silicon, via the
exact `zest_query` calls the Swift app makes:

| Typing… | Debug lib + old dedup (the app today) | ReleaseFast + old dedup | ReleaseFast + O(1) dedup (fixed) | fixed + cap 1k |
|---|---|---|---|---|
| `i` | **82,799 ms** | 4,458 ms | 17.8 ms | 0.1 ms |
| `in` | (similar) | 3,311 ms | 23.4 ms | 0.2 ms |
| `inv` | — | 368 ms | 134 ms | 7.9 ms |
| `invoice` | — | 136 ms | 135 ms | 82.8 ms |

Five compounding causes, in order of impact:

1. **O(n²) duplicate check** in the text-search hot loop
   (`src/index/search.zig`) — every match linearly scanned all accumulated
   results. At `maxResults: 100_000`, a 1-char query did ~5×10⁹ comparisons.
   **Fixed** (entry indices are monotonic in blob order → compare against the
   last seen index only): 4,458 ms → 17.8 ms for `i`.
2. **The app links a Debug `libzest-core.a`** — `just build` runs plain
   `zig build`; Package.swift links whatever is in `zig-out/lib`. Debug is
   ~19× slower than ReleaseFast on this workload (82.8 s vs 4.5 s).
3. **Every UI change runs the query pipeline 2×, synchronously, on the main
   thread** — `onChange` → `browser.reload()` (query #1) and
   `filterBar.refresh()` (query #2, a full query+sort discarded for a count).
   A search-field commit fires `onChange` twice (scope change + text change)
   → 4 pipeline passes per keystroke.
4. **100,000-row cap, fully materialized** — every pass copies up to 100k rows
   into Swift (2 String allocs/row), sorts with
   `localizedCaseInsensitiveCompare` (~1.7M ICU comparisons), and formats
   size/date for every row eagerly (`ByteCountFormatter` ≈ µs/row) though only
   ~30 are visible. NSTableView itself is virtualized; the eager mapping isn't.
5. **The daemon rebuilds forever** — FSEvents watches `$HOME` *including the
   daemon's own output dir*, so every rebuild triggers the next one 30 s later
   (~23 s of I/O each). Meanwhile the Swift app **never reloads the index**
   (mmap once at init), so all that work is invisible until app restart — and
   stale rows make `navigate()`/double-click silently no-op on renamed/deleted
   folders.

The "broken" search bar and address bar are *not* unwired — the event chains
are intact (`SearchField` → debounce → `commit` → `queryText` → `onChange`;
`Breadcrumb` Enter → `navigate`). They are starved: one keystroke queues
minutes of synchronous main-thread work, so the UI stops responding entirely.
Double-click misses come from `reloadData()` + select-row-0 + scroll-to-top on
every change (destroys the clicked row mid-double-click), stale-index
`navigate()` silently failing, and the same main-thread starvation.

## Phase A — Make it usable (perf-critical path)

- [x] **A1. O(1) search dedup** (`src/index/search.zig`) — done, 250× on
  short queries. Zig tests pass; result counts byte-identical.
- [ ] **A2. Ship the engine in ReleaseFast** — `just build` / `run` must build
  `libzest-core.a` with `-Doptimize=ReleaseFast` (Debug Zig lib is ~19×
  slower; there is no reason the *engine* should ever be Debug, even in dev).
- [ ] **A3. Sane result cap** — drop `maxResults` from 100,000 to ~2,000 in
  `AppCoordinator.results()`; filter bar shows "2,000+" when capped.
  (Benchmarked: worst keystroke ≤ ~135 ms = the full-blob-scan floor.)
- [ ] **A4. One query per change** — cache the result set per change-tick in
  `AppCoordinator` so `browser.reload()` and `filterBar.refresh()` share one
  query; wrap `SearchField.commit` (scope + text) in `withoutNotifying` so a
  keystroke fires `onChange` once, not twice. Net: 4 passes/keystroke → 1.
- [ ] **A5. Query off the main thread** — serial background queue + generation
  counter in `AppCoordinator` (the sidebar histogram already does exactly
  this pattern); deliver on main, drop stale generations. Optionally expose
  the existing cancellable search (`search.zig` already supports a
  generation atomic) through the C ABI.
- [ ] **A6. Stop the daemon rebuild treadmill** — set
  `kFSEventStreamCreateFlagIgnoreSelf` and/or `FSEventStreamSetExclusionPaths`
  for `~/Library/Application Support/zest` in `src/index/fsevents.zig` /
  `daemon.zig`; filter those paths in `onFSEvent` before counting dirty events.
- [ ] **A7. Index hot-reload in Swift** — poll the index inode/mtime (~5 s
  timer) in `ZestCore`/`AppCoordinator`; on change, build a new `ZestCore`,
  swap, release the old (rows are copied at the FFI boundary, so no dangling
  pointers). Also retry when launched before the first index exists
  (`core == nil` is currently permanent).

## Phase B — UX correctness

- [ ] **B1. Fix double-click reliability** — stop `reloadData()` +
  select-row-0 + `scrollRowToVisible(0)` on every change; preserve
  selection/scroll on refresh; only reset on actual navigation.
- [ ] **B2. Navigation feedback** — `navigate()`'s `guard` currently fails
  silently (stale paths, typos in address bar). Beep / shake / status-bar
  message on failure.
- [ ] **B3. Lazy row formatting** — format size/date in
  `tableView(_:viewFor:row:)` for visible rows only (or memoize); replace
  `ByteCountFormatter` with a hand-rolled formatter; sort on precomputed
  lowercase keys instead of `localizedCaseInsensitiveCompare` per comparison.
- [ ] **B4. Subtree query fast path** (`search.zig` filter-only path with
  `max_depth > 1`) — mark subtree dirs once (reuse `markSubtreeDirs`), then
  test parent-id membership per entry instead of `buildResult` + string
  prefix compare for all 5.5M entries.
- [ ] **B5. Fix subtree ext-breakdown merge** (`src/index/subtree.zig`) — the
  hash key is the storage *offset* (always unique) instead of the name, so
  per-extension counts never merge across dirs; sidebar shows duplicate
  split rows. Key by name bytes (`std.StringHashMap` over slices into the
  index buffer).
- [ ] **B6. Empty/loading/no-index states** (redesign spec §6.4 +
  ARCHITECTURE.md known-gaps) — today a missing `index.zst` silently shows
  zero rows and `core == nil` is permanent. Add: no-index state with copy
  ("run `just index`"), no-results state, and a loading indicator once
  queries are async (A5).

## Phase C — Hardening (corrupt-index & daemon robustness)

- [ ] C1. `@enumFromInt` on disk bytes (`reader.zig`, `bitmap.zig`) — use
  `std.enums.fromInt(...) orelse default` (a corrupt byte currently panics).
- [ ] C2. `getDirPath` missing `dir_offset <= next_offset` bounds check
  (`reader.zig`).
- [ ] C3. `cnt * 4` u32 overflow on disk-read count (`bitmap.zig`).
- [ ] C4. Validate `num_entries` against `data.len` in reader init; consider a
  header checksum for the format.
- [ ] C5. Escape `\t`/`\n` in scan lines (legal in APFS filenames; currently
  corrupt the TSV records) — or move to length-prefixed records.
- [ ] C6. Worker-pool deadlock: `pending` counts subdirs whose queue-append
  failed (`bulk_scan.zig`) — count only successful appends.
- [ ] C7. Lazy bitmap init race (`reader.zig:getCategoryBitmaps`) — becomes a
  real data race once queries move off-main (A5). Init eagerly+fatally in
  `zest_open`, or guard with a once/mutex.
- [ ] C8. C ABI error reporting — `zest_query` returns null for OOM and
  >256-byte queries alike; Swift shows silent empty results. Add an error
  out-param.

## Phase D — Cleanup, docs, repo hygiene

- [ ] **D1. Archive the legacy Zig GUI** — the Swift app superseded it. Dead
  chain (confirmed by import graph): `src/ui/*` (8 files), `src/main.zig`,
  `src/app.zig`, `src/core/{async_search,dispatch,navigator,user_state,
  fake_fs,real_fs,fs_provider}.zig`, `src/index/session.zig`. Port
  `session.zig`'s inode-poll logic to Swift (A7) first, then delete the
  chain + the `zest` executable from `build.zig` (it links AppKit and slows
  every build). Keep: indexer chain + capi chain + shared core files.
- [ ] **D2. Rewrite CLAUDE.md** — it still describes the pure-Zig AppKit app
  and the 5s stat-poll; the real architecture is Swift UI + libzest-core.a
  (see docs/ARCHITECTURE.md, which is accurate).
- [ ] **D3. README drift** — references `just dev` / `just bench` recipes that
  don't exist; add `bench-capi`; fold in the new perf numbers.
- [ ] D4. Address the 8 naming/`TODO` comments in `SidebarViewController.swift`
  and the `settingProgrammatically` hack note in `SearchField.swift`.
- [ ] D6. Delete `Sample of Zest.txt` from the repo root — a committed
  213KB `sample(1)` profiler dump from the 2026-06-06 lag investigation,
  superseded by `benchmarks/bench_capi.zig` + docs/ROADMAP.md.
- [ ] D5. Commit policy: `Sources/Zest/App/AppCoordinator.swift` working-tree
  diff is a pure re-format (2→4-space) + one stray `).d` typo in a doc
  comment — fix the typo, settle on one swift-format config, commit.

## Phase E — Features (post-stability)

- [ ] E1. Saved-filters manager (the toolbar "Saved ▾" button is a render-only
  stub).
- [ ] E1b. **Real pins + folder colors in the Swift app** — sidebar pins are
  hardcoded (`SidebarViewController.pins()`, explicit TODO); the old app's
  `pins.json` / `folder_colors.json` (still on disk in app support) are
  ignored. Decision needed: expose `zest_pins_* / zest_filter_* /
  zest_folder_color` via the C ABI as the redesign spec §3.2 drew it, or
  (recommended) persist this UI state Swift-side and let `user_state.zig`
  retire with the legacy GUI (D1). The spec's pass-through FFI was drawn
  before the Swift app owned its own persistence.
- [ ] E1c. Theme manager + light mode + accent source (`auto`/preset/hex) —
  spec §4.2/§4.5/§13.7: `Theme.deriveAccent` already supports `.light`, but
  every call site hardcodes `.dark` and nothing follows
  `NSApp.effectiveAppearance` or reads an appearance config. Includes the
  Settings island (SwiftUI via NSHostingController) from spec §3.3.
- [ ] E1d. Command model / full keyboard reachability (spec §6.2 + §8) —
  `CommandRouter` + responder-chain routing, toggleSidebar, revealInFinder,
  focusSearch, ↑/↓/Return everywhere; today only a subset exists
  (Enter-to-open, menu shortcuts).
- [ ] E1e. App bundle (ARCHITECTURE.md known-gaps) — `Zest` runs as an
  unbundled executable; a real `.app` with Info.plist gets Dock icon,
  Finder metadata, and file-association handling. Status-bar
  click-to-copy indexed count (spec §15.D) is a one-liner to fold in
  whenever the status bar is touched.
- [ ] E2. Dir→entry-range table in the index format (v4) — O(children) folder
  listings and O(log D) `findDirId` (currently a linear scan of the dir
  table per depth-1 query).
- [ ] E3. SIMD substring scan (`@Vector`) or memchr-style skipping — the
  full-blob scan floor is ~135 ms; this is the next search-latency win
  after A3/A5.
- [ ] E4. Unicode case folding (currently ASCII-only — "Übersicht" won't match
  case-insensitively).
- [ ] E5. Drag & drop out of the file list.
- [ ] E6. Incremental / FSEvents-scoped partial reindex (today every rebuild
  re-walks all of `$HOME`, ~23 s + transient RAM spike).
- [ ] E7. Multi-window / tabs, QuickLook preview, rename-in-place — Finder
  parity features, prioritize by usage.

## Benchmarks

`benchmarks/bench_capi.zig` is the regression harness for the engine. Baseline
(2026-06-09, M-series, 5.56M entries): see table above; full results in git
history of this file. Method: mmap real index, 1 warmup + 7 samples (or 1
sample if warmup > 5 s), median reported; drain pass measures FFI row-copy
cost separately (it's ≤ 6 ms / 100k rows — data transfer was never the
bottleneck; rendering eagerness and the engine were).

## Archived docs

Moved to `docs/archive/` (completed or superseded, kept for history):

- `TODO.md` — phase tracker for the *Zig* UI (superseded by the Swift app)
- `PLAN.md` — original Zig 0.15.2-era project plan
- `superpowers/plans/2026-06-06-zest-ui-phase0-ffi-foundation.md` — Phase 0
  complete (FFI foundation shipped)
- `superpowers/specs/2026-05-30-unified-query-file-list-design.md` —
  implemented (browse == query is how the app works today)

Still live: `docs/ARCHITECTURE.md` (accurate),
`docs/superpowers/specs/2026-06-06-gui-redesign-design.md` (the GUI redesign
is the active workstream).
