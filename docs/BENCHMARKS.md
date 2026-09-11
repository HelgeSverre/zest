# Zest — Benchmarks

Numbers, not gates. Re-run the matching recipe after any engine or UI change
and update the table here. Medians over 7 samples.

`benchmarks/bench_capi.zig` is the regression harness for the engine. Baseline
(2026-06-09, M-series, 5.56M entries): full results in git history of
`docs/archive/ROADMAP.md`. Method: mmap real index, 1 warmup + 7 samples (or 1
sample if warmup > 5 s), median reported; drain pass measures FFI row-copy
cost separately (it's ≤ 6 ms / 100k rows — data transfer was never the
bottleneck; rendering eagerness and the engine were).

Post-stabilization (2026-06-10,
ReleaseFast):

| op | median |
|---|---|
| search `i` @100k cap | 17.0 ms |
| search `i` @2k (the app's cap) | ≤ 0.2 ms |
| search `invoice` @2k | ~65 ms (full-blob-scan floor) |
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

> **Review sweep (2026-09-11, M2 Max, 4.09M entries, same index file for both
> engines):** result counts identical for every op before/after. `ext_breakdown
> x9 subtree` 63.6 → 49.9 ms median (one redundant bucket walk removed);
> search medians unchanged within noise. Full scan: build 1.9 → 1.6 s, peak
> RSS 1.80 → 1.59 GB, walk unchanged (kernel-bound: 12 threads doubled sys
> time, 8 stays). Daemon rebuilds are now incremental: merge 0.1–0.3 s +
> build 0.8 s + write 0.6 s instead of a 17 s / 60 CPU-second full walk.

## Synthetic harness (`just bench-search`)

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

## UI benchmark (`just bench-app`)

`Zest --bench` (`Sources/Zest/App/Bench.swift`) measures everything *above*
the engine: it builds the real `RootViewController` in an off-screen window
(the `--snapshot` trick), drives the real `AppCoordinator` through a scripted
scenario — navigate `~` → `~/Library` → `~/Library/Application Support` → `~`,
type `r`/`re`/`rea`/`read`/`readme`, a filter-only `cat:code`, clear — and
reports two numbers per step, median and p90 over 7 iterations (`--iterations
N`, `--json` for scripting):

- **query** — from the coordinator mutation until the fresh rows land on main
  (the second `onChange` of that generation, `isLoading == false`). This is the
  engine call + off-main sort + FFI row copy + every observer's refresh
  (`browser.reload()`, sidebar histogram, filter bar, status bar).
- **render** — a forced full layout + `cacheDisplay` of the window afterwards,
  i.e. the cost of drawing the whole chrome once; it is roughly constant and
  mostly there to catch a view that suddenly becomes expensive to draw.

`rows` is the delivered row count (2000 = the UI cap). "clear search" keeps the
subfolders scope, as the real search field does, so it is a capped subtree
listing rather than a folder browse. Needs an index; exits 1 with a hint
otherwise. Requires a Release build of the Swift app (the recipe does this) —
Debug numbers are not comparable.

2026-09-11, M-series, ReleaseFast core + Release app, 7 iterations:

```
step                                query med   query p90  render med  render p90    rows
open ~                                   15.3        16.0        13.1        13.5      42
open ~/Library                           24.7        26.1        13.4        14.3     118
open ~/Library/Application Support       26.9        27.0        13.7        14.2     259
back to ~                                26.4        28.5        13.0        13.7      42
type 'r'                                 25.6        26.5        13.0        13.2    2000
type 're'                                31.4        32.3        11.5        13.2    2000
type 'rea'                               31.9        32.6        13.1        13.5    2000
type 'read'                              28.7        29.9        13.1        13.5    2000
type 'readme'                            29.2        30.2        13.1        14.0    2000
filter cat:code                          40.6        42.1        14.6        14.7    2000
clear search                             32.7        32.7        12.3        12.5    2000

7 iterations, 11 steps, total wall 3.52 s
```

Reading it against `bench-capi`: the engine returns a depth-1 folder listing
in ~5 ms and a capped 2k search in well under a millisecond, so the 15–40 ms
"query" figures are dominated by the Swift side (observer refreshes, the
sidebar histogram/ext-breakdown, table reload) — that is where a UI regression
will show up.

