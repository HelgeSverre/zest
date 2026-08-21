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
- [x] **A2. Ship the engine in ReleaseFast** — `just build` / `run` must build
  `libzest-core.a` with `-Doptimize=ReleaseFast` (Debug Zig lib is ~19×
  slower; there is no reason the *engine* should ever be Debug, even in dev).
- [x] **A3. Sane result cap** — drop `maxResults` from 100,000 to ~2,000 in
  `AppCoordinator.results()`; filter bar shows "2,000+" when capped.
  (Benchmarked: worst keystroke ≤ ~135 ms = the full-blob-scan floor.)
- [x] **A4. One query per change** — cache the result set per change-tick in
  `AppCoordinator` so `browser.reload()` and `filterBar.refresh()` share one
  query; wrap `SearchField.commit` (scope + text) in `withoutNotifying` so a
  keystroke fires `onChange` once, not twice. Net: 4 passes/keystroke → 1.
- [x] **A5. Query off the main thread** — serial background queue + generation
  counter in `AppCoordinator` (the sidebar histogram already does exactly
  this pattern); deliver on main, drop stale generations. Optionally expose
  the existing cancellable search (`search.zig` already supports a
  generation atomic) through the C ABI.
- [x] **A6. Stop the daemon rebuild treadmill** — set
  `kFSEventStreamCreateFlagIgnoreSelf` and/or `FSEventStreamSetExclusionPaths`
  for `~/Library/Application Support/zest` in `src/index/fsevents.zig` /
  `daemon.zig`; filter those paths in `onFSEvent` before counting dirty events.
- [x] **A7. Index hot-reload in Swift** — poll the index inode/mtime (~5 s
  timer) in `ZestCore`/`AppCoordinator`; on change, build a new `ZestCore`,
  swap, release the old (rows are copied at the FFI boundary, so no dangling
  pointers). Also retry when launched before the first index exists
  (`core == nil` is currently permanent).

## Phase B — UX correctness

- [x] **B1. Fix double-click reliability** — stop `reloadData()` +
  select-row-0 + `scrollRowToVisible(0)` on every change; preserve
  selection/scroll on refresh; only reset on actual navigation.
- [x] **B2. Navigation feedback** — `navigate()`'s `guard` currently fails
  silently (stale paths, typos in address bar). Beep / shake / status-bar
  message on failure.
- [x] **B3. Lazy row formatting** — format size/date in
  `tableView(_:viewFor:row:)` for visible rows only (or memoize); replace
  `ByteCountFormatter` with a hand-rolled formatter; sort on precomputed
  lowercase keys instead of `localizedCaseInsensitiveCompare` per comparison.
- [x] **B4. Subtree query fast path** (`search.zig` filter-only path with
  `max_depth > 1`) — mark subtree dirs once (reuse `markSubtreeDirs`), then
  test parent-id membership per entry instead of `buildResult` + string
  prefix compare for all 5.5M entries.
- [x] **B5. Fix subtree ext-breakdown merge** (`src/index/subtree.zig`) — the
  hash key is the storage *offset* (always unique) instead of the name, so
  per-extension counts never merge across dirs; sidebar shows duplicate
  split rows. Key by name bytes (`std.StringHashMap` over slices into the
  index buffer).
- [x] **B6. Empty/loading/no-index states** (redesign spec §6.4 +
  ARCHITECTURE.md known-gaps) — today a missing `index.zst` silently shows
  zero rows and `core == nil` is permanent. Add: no-index state with copy
  ("run `just index`"), no-results state, and a loading indicator once
  queries are async (A5).

## Phase C — Hardening (corrupt-index & daemon robustness)

- [x] C1. `@enumFromInt` on disk bytes (`reader.zig`, `bitmap.zig`) — use
  `std.enums.fromInt(...) orelse default` (a corrupt byte currently panics).
- [x] C2. `getDirPath` missing `dir_offset <= next_offset` bounds check
  (`reader.zig`).
- [x] C3. `cnt * 4` u32 overflow on disk-read count (`bitmap.zig`).
- [x] C4. Validate `num_entries` against `data.len` in reader init; consider a
  header checksum for the format.
- [x] C5. Escape `\t`/`\n` in scan lines (legal in APFS filenames; currently
  corrupt the TSV records) — or move to length-prefixed records.
- [x] C6. Worker-pool deadlock: `pending` counts subdirs whose queue-append
  failed (`bulk_scan.zig`) — count only successful appends.
- [x] C7. Lazy bitmap init race (`reader.zig:getCategoryBitmaps`) — becomes a
  real data race once queries move off-main (A5). Init eagerly+fatally in
  `zest_open`, or guard with a once/mutex.
- [ ] C8. C ABI error reporting — `zest_query` returns null for OOM and
  >256-byte queries alike; Swift shows silent empty results. Add an error
  out-param.

## Phase D — Cleanup, docs, repo hygiene

- [x] **D1. Archive the legacy Zig GUI** — the Swift app superseded it. Dead
  chain (confirmed by import graph): `src/ui/*` (8 files), `src/main.zig`,
  `src/app.zig`, `src/core/{async_search,dispatch,navigator,user_state,
  fake_fs,real_fs,fs_provider}.zig`, `src/index/session.zig`. Port
  `session.zig`'s inode-poll logic to Swift (A7) first, then delete the
  chain + the `zest` executable from `build.zig` (it links AppKit and slows
  every build). Keep: indexer chain + capi chain + shared core files.
- [x] **D2. Rewrite CLAUDE.md** — it still describes the pure-Zig AppKit app
  and the 5s stat-poll; the real architecture is Swift UI + libzest-core.a
  (see docs/ARCHITECTURE.md, which is accurate).
- [x] **D3. README drift** — references `just dev` / `just bench` recipes that
  don't exist; add `bench-capi`; fold in the new perf numbers.
- [ ] D4. Address the 8 naming/`TODO` comments in `SidebarViewController.swift`
  and the `settingProgrammatically` hack note in `SearchField.swift`.
- [x] D6. Delete `Sample of Zest.txt` from the repo root — a committed
  213KB `sample(1)` profiler dump from the 2026-06-06 lag investigation,
  superseded by `benchmarks/bench_capi.zig` + docs/ROADMAP.md.
- [x] D5. Commit policy: `Sources/Zest/App/AppCoordinator.swift` working-tree
  diff is a pure re-format (2→4-space) + one stray `).d` typo in a doc
  comment — fix the typo, settle on one swift-format config, commit.

## Phase E — Features (post-stability)

- [ ] E1. Saved-filters manager (the toolbar "Saved ▾" button is a render-only
  stub).
- [x] E1b. **Real pins + folder colors in the Swift app** *(pins + colors
  done 2026-06-10 via Swift `UserState`; saved-filters manager remains E1)* — sidebar pins are
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
- [x] E3. **SIMD substring scan (`@Vector`)** *(done 2026-08-14)* — the
  two-anchor filter compares a whole register of head bytes and a whole
  register of tail bytes per step (`nextCandidate` in `search.zig`), width from
  `std.simd.suggestVectorLength`, so it is NEON on Apple Silicon and SSE2/AVX2
  on x86 without per-arch code. The raw scan went from ~1.1 GB/s to ~17 GB/s;
  end-to-end query numbers in the table below.
- [x] E4. **Unicode case folding** *(done 2026-08-14)* — `core/casefold.zig`
  folds the name blob and the query with the same length-preserving map, so
  "Übersicht", "ΕΛΛΑΔΑ" and "Москва" match in any case. Index format v7 (the
  writer rebuilds in v7; the layout-compatible v6 reader fallback keeps the
  app usable with ASCII matching until that rebuild lands).
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

Post-stabilization (2026-06-10, after the A5–A7 + Phase B + Phase C rounds;
ReleaseFast):

| op | median |
|---|---|
| search `i` @100k cap | 17.0 ms |
| search `i` @2k (the app's cap) | ≤ 0.2 ms |
| search `invoice` @2k | ~65 ms (full-blob-scan floor — E3 is the next win) |
| browse (folder listing) | 5.1 ms |
| histogram depth=1 / subtree | 0.0 / 1.2 ms |
| ext_breakdown ×9 depth=1 / subtree | 0.0 / 83 ms (merge fix also sped it up) |

> **Result-count note (2026-07-17, index v4):** directory entries now carry
> their recursive subtree size in the size column, so `size:` queries also
> match folders. Result counts for size-filtered queries are intentionally
> higher than the pre-v4 baselines — not a regression.

All engine queries now run off the main thread in the app (generation-dropped
staleness), so even the 65–135 ms floors never block the UI. Depth-1 sidebar
reads dropped to ~0 ms once the daemon rebuild treadmill stopped churning the
page cache. Since 2026-08-14 a superseded query is also *cancelled* rather than
merely dropped on delivery (`zest_query_cancellable`), so the scan behind a
keystroke stops instead of holding the serial query queue.

### Synthetic harness (`just bench-search`)

`bench_capi.zig` needs the developer's real `index.zst`; `bench_search.zig`
builds a deterministic 1M-entry corpus in memory instead, so an engine change
can be measured on any machine (CI included) and A/B'd against the previous
build with the same seed.

E3 + E4, 1M entries (68.6 MB index, ~20 MB name blob), x86_64 AVX2 @ 2.1 GHz,
ReleaseFast, median of 7:

| query | before | after | |
|---|---|---|---|
| `e` (1 char, 100k cap) | 12.5 ms | 10.3 ms | cap-bound, not scan-bound |
| `re` | 15.2 ms | 10.2 ms | 1.5× |
| `report` | 20.8 ms | 5.4 ms | 3.8× |
| `screenshot` | 16.2 ms | 4.6 ms | 3.5× |
| no match (pure scan) | 7.4 ms | 0.56 ms | 13× |
| `café` | 14.7 ms → **0 rows** | 4.7 ms → **35,289 rows** | E4: previously unmatchable |
| folder listing (depth 1) | 1.22 ms | 1.38 ms | unchanged path |
| subtree `ext:pdf` | 28–30 ms | 32–38 ms | unchanged path; run-to-run noise on this box is ±15% |

Caveats worth keeping in mind when reading these: the box is a 4-core cloud VM
with visibly noisy timings (the `ext:pdf` filter-only path is untouched by
these changes and still swings 28–38 ms across runs), and Apple Silicon is a
16-byte NEON register against this machine's 32-byte AVX2, so the scan speedup
there will be smaller. Re-run `just bench-capi` on the real index before
quoting numbers for macOS.

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
