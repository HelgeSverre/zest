# Recursive Folder Sizes — Design

**Date:** 2026-07-17
**Status:** Approved for implementation

## Goal

Show the total recursive size of a folder in the Size column (currently "—").
Folder sizes participate fully in sort-by-size and `size:` filters. Display is
just the formatted size (e.g. "1.2 GB") — no item counts.

## Approach

Bake subtree sizes into the existing per-entry `size` column at index-build
time. Sizes come from the index (freshness = daemon rebuild + 5s hot-reload
poll); zero query-time cost, zero format-layout change.

The scanner already writes `size = 0` for directories (`ATTR_FILE_DATALENGTH`
is absent for dirs in the `getattrlistbulk` reply), and the `size:` filter and
`sortResults` read `result.size` directly — so once the column holds real
values for folders, sort/filter participation falls out with no engine changes.

## Changes

### 1. Builder (`src/index/format.zig` → `writeIndex`)

Compute a `sizes: []u64` array and write it in place of `entry.size` when
emitting the metadata column (line ~313):

1. **Local sums** — one pass over entries: `local[parent_id] += entry.size`
   for non-directory entries. (Dir entries are size 0 from the scanner;
   skipping them is defensive against double-counting if that ever changes.)
2. **Roll-up** — sort dir ids by path length descending (a child's path is
   strictly longer than its parent's, so this is a valid bottom-up topological
   order), then one pass adding `total[d]` into `total[parent_of(d)]`.
   `parent_of` is a dirname lookup in the existing `dir_table` hash — exact
   match, so no `/a/b` vs `/a/bc` prefix-collision risk. Roll-up stops
   naturally when the parent path isn't in the table (scan root's parent).
3. **Assign to folder entries** — for each `kind == .directory` entry, look up
   its own full path (`dir_path ++ "/" ++ name`) in `dir_table`;
   `sizes[i] = total[dir_id]`. Empty dirs aren't in the dir table → 0.
   Join defensively: a `dir_path` of `"/"` must not produce `"//name"`
   (can't occur with a `$HOME` scan root, but `writeIndex` is generic).

Complexity: O(N + D log D), N ≈ 5.5M entries, D ≈ hundreds of thousands of
dirs — noise next to the disk scan. Confirm by timing `just index`
before/after.

### 2. Format version

Bump `format.VERSION` 3 → 4. Layout is unchanged; the semantics of the size
column changed for directory entries. The reader's version check forces a full
reindex on first launch with the new build, so folders never display stale
zeros.

### 3. Engine / C ABI / Swift FFI

**No changes.** Reader, search scan, sort, size filters, `zest_query_row`, and
`ZestCore.query` all consume the same column.

### 4. Swift UI (`Sources/Zest/Browser/BrowserViewController.swift`)

`sizeText` (line 31) drops the directory special case:

```swift
lazy var sizeText: String = Self.formatSize(size)
```

An empty (or all-hidden-content) folder shows the zero-size string rather than
"—" — honest, and consistent with how filters now treat it.

### 5. Documented caveats (ARCHITECTURE.md)

- Logical sizes (Σ `st_size`): hard links double-count, sparse files
  overstate; not on-disk block usage.
- Only indexed content counts: dotfiles and excluded dirs
  (`config.shouldExclude` / `shouldExcludePath`) are invisible to the sum, so
  folder sizes can undercount vs `du`.
- Freshness = index freshness.
- **Intentional invariant break:** `size:` query result counts change (folders
  now match). Note this in ROADMAP.md next to the bench baseline so the
  before/after count comparison isn't misread as a regression.

### 6. Tests

Zig (embedded, rooted at `src/test_root.zig`):

- Multi-level roll-up: `/a/b/c` file sizes appear in `/a/b` and `/a` totals.
- Empty dir entry → size 0.
- Sibling-prefix dirs (`/a/b` vs `/a/bc`) don't bleed into each other.
- `size:>X` filter matches a folder whose subtree exceeds X.
- Sort-by-size interleaves folders and files by their (subtree) sizes.

Swift (`Sources/ZestTests`): `FileItem.sizeText` formats a real size for
directories.

### 7. Benchmarks

- `just bench-capi` before/after — expect identical timings (no query-path
  change); size-query result counts change intentionally.
- Full `just index` wall-clock before/after — roll-up cost should be noise.
- Keep `zig-out/lib/libzest-core.a` in ReleaseFast when benchmarking.

## Out of scope (possible later)

- Recursive item counts (same roll-up, a u32 next to the u64; would need a
  per-dir column or a second baked column).
- On-disk (block) sizes.
- Live/du-style recomputation.
