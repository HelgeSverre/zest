# Zest — Architecture

A minimal, fast Finder replacement for macOS. Three artifacts (one daemon, one
static lib, one GUI app) cooperate through a single shared file: the columnar
index on disk.

> **One-line summary**: `zest-indexer` (Zig daemon) walks `~/` and writes a
> mmap-friendly binary index; `Zest.app` (Swift/AppKit) mmaps the same file and
> calls `libzest-core.a` (Zig, C ABI) to search it.

## The three artifacts

| Artifact            | Type          | Source root                     | What it does                                                                |
| ------------------- | ------------- | ------------------------------- | --------------------------------------------------------------------------- |
| `zest-indexer`      | CLI / daemon  | `src/indexer_main.zig`          | Walks the filesystem, writes the index, watches for changes.               |
| `libzest-core.a`    | Static lib    | `src/zest_core_lib.zig`         | Pure-CPU search engine exposed as a C ABI (reader + query + bitmap filter). |
| `Zest.app`          | Swift GUI     | `Sources/Zest/...`              | Native AppKit window; links `libzest-core.a`; mmaps the index.              |

The legacy pure-Zig GUI (`src/main.zig`, `src/app.zig`, `src/ui/`, and related
Zig files) has been deleted. The Swift app is the only GUI.

## Roles of the two languages

### Zig — the engine

- The whole "is this file big / new / a PDF / named report" decision is Zig.
- The index format, the bulk scanner, the FSEvents watcher, the SIMD substring
  search, the bitmap intersection, and the `cat:` / `ext:` / `kind:` parser are
  all Zig.
- The daemon is a small, focused process. It has no UI, no networking, no
  shared state. It just produces one file.
- The static library has *no* `main` and *no* `Io` handle — it borrows caller-
  provided bytes (a Swift mmap) for the lifetime of the Core. This makes it
  trivial to embed in any host.

### Swift — the shell

- Window chrome, AppKit wiring, keyboard shortcuts, table view, sidebar tree,
  context menus, the "Open in Finder" / "Open in Terminal" calls, the
  pin/filter config persistence.
- Nothing search-shaped is in Swift. The UI never iterates an index — it
  asks `ZestCore.query(...)` and gets back a borrowed `Row` struct for each hit.
- A single `ZestCore` instance owns the mmap for the index file and the Core
  handle from `zest_open`. Every other component goes through it.

## The shared file: `index.zst`

The indexer and the GUI agree on a single file:

```
~/Library/Application Support/zest/index.zst
```

It's a custom binary format (`src/index/format.zig`, magic `"ZESTINDX"`,
64-byte header) with a columnar layout:

```
┌────────────────────── HEADER (64 bytes) ──────────────────────┐
│ magic │ version │ num_entries │ created_at │ 4 × section_off  │
├──────────────────── NAMES column ─────────────────────────────┤
│ u32 offsets[num] │ u16 lengths[num] │ u32 blob_len │ blob     │
│                                       │ u32 lower_len │ lower  │
├──────────────────── PATHS column ─────────────────────────────┤
│ u32 parent_id[num]  (entry → dir table)                        │
│ u32 dir_count                                                    │
│ u32 dir_offsets[dir_count] │ u32 dir_blob_len │ dir_blob       │
├──────────────────── METADATA column ──────────────────────────┤
│ u64 size[num] │ i64 mtime[num] │ u8 kind[num] │ u8 cat[num]    │
│   (v4: directory entries' size = recursive subtree total,       │
│    rolled up at build time; files keep their scanned st_size)   │
├──────────────────── BITMAPS ───────────────────────────────────┤
│ u32 num_bitmaps                                                  │
│ for each: u8 cat │ u32 count │ u32 indices[count] (sorted)      │
└─────────────────────────────────────────────────────────────────┘
```

Why columnar:

- The lowercased-name blob is one contiguous `[]u8` that SIMD substring search
  can scan in a single pass. The row index is recovered by binary search
  through the `u32` offsets array. The scan compares two `@Vector(N, u8)`
  registers per step — the bytes at the candidate position against the query's
  first character, and the bytes `qlen - 1` further on against its last — and
  ANDs the masks, so one instruction rejects 16 positions on Apple Silicon (32
  under AVX2) and only survivors reach the full `memcmp`. `N` comes from
  `std.simd.suggestVectorLength`, so there are no per-architecture code paths.
- The blob is UTF-8 case-*folded*, not ASCII-lowercased (`core/casefold.zig`),
  with the same fold applied to the query. Folding is length-preserving by
  construction, which is what lets one `(offset, length)` pair address a name
  in both blobs. The v7 reader also accepts layout-compatible v6 indexes and
  uses their ASCII query fold during a rolling upgrade; Unicode matching turns
  on when the daemon publishes the next v7 index.
- The `u8 kind` / `u8 category` arrays plus the per-category sorted `u32` index
  lists let the search engine eliminate rows that don't match a `cat:code` /
  `ext:pdf` filter in O(1) per candidate (binary search on a sorted bitmap).
- Directory paths are stored once in a prefix-deduped table; each entry holds
  just the 4-byte `parent_id` index.

## The C ABI surface

`libzest-core.a` exports fourteen functions (`src/capi/zest_core.zig`):

```c
Core*     zest_open          (const uint8_t* bytes, size_t len);   // borrow bytes
void      zest_close         (Core*);
size_t    zest_count         (Core*);                              // num_entries
Query*    zest_query         (Core*, const char* q, const char* scope,
                              uint32_t max_depth, uint32_t max_results);
Query*    zest_query_cancellable (Core*, const char* q, const char* scope,
                              uint32_t max_depth, uint32_t max_results,
                              CancelToken*, uint32_t* out_status);
size_t    zest_query_count   (const Query*);
ZestRow   zest_query_row     (const Query*, size_t i);             // borrows into mmap
void      zest_query_free    (Query*);
CancelToken* zest_cancel_token_create  (void);
void      zest_cancel_token_destroy    (CancelToken*);
void      zest_cancel_token_cancel     (CancelToken*);             // any thread
ZestHistogram zest_histogram (Core*, const char* scope, uint32_t max_depth);
uint32_t  zest_ext_breakdown (Core*, const char* scope, uint32_t max_depth,
                              uint8_t cat, uint32_t max, ZestExtCount* out);
size_t    zest_casefold_utf8 (const uint8_t* input, size_t len,
                              uint8_t* out, size_t out_capacity);
```

`ZestRow` is a fixed-layout `extern struct` (name, dir_path, size, mtime, kind,
category) that Swift consumes through a Clang-imported `zest_core.h` — the
layout cannot drift. Strings borrow into the index mmap; Swift copies them to
`String` immediately on receipt. `zest_histogram` returns a 9-element
per-category count array for the sidebar histogram. `zest_ext_breakdown`
returns the top-N extensions for a (scope, category) pair, sorted by count
descending, for the sidebar's drill-down rows. `zest_casefold_utf8` lets the
Swift filter model canonicalize `ext:` values with the same mapping as the
engine instead of Foundation's observably different Unicode lowercasing.

`zest_query_cancellable` is `zest_query` plus a cancel token. The token is one
atomic word; the engine polls it every 64 KiB of blob (or every 512 entries on
the filter path) and unwinds with `ZEST_QUERY_CANCELLED` when it is set. The
Swift coordinator creates one token per change-tick and cancels the previous
tick's token before dispatching the next query — so a keystroke that supersedes
an in-flight scan stops it instead of queueing behind it on the serial query
queue. `zest_query` is the same call with a null token.

## End-to-end data flow

The full path of a search, from the kernel to a visible table row:

```
                     ┌─────────────────┐
                     │ macOS filesystem│  ~/
                     │  (kernel)       │
                     └────────┬────────┘
                              │ getattrlistbulk (8 worker threads)
                              ▼
                     ┌─────────────────┐
                     │ bulk_scan.zig   │  per-worker .scan.tmp.N (TSV)
                     └────────┬────────┘
                              │ read back, build columnar
                              ▼
                     ┌─────────────────┐
                     │ builder.zig     │
                     │   → .tmp file   │  atomic rename
                     └────────┬────────┘
                              │
                              ▼
       ┌──────────────────────────────────────┐
       │ ~/Library/Application Support/zest/  │
       │           index.zst                  │ ◀──── mmap()'d by Swift at startup
       │                                      │       (PROT_READ, MAP_PRIVATE)
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
                       │  [SearchResult] {index,name,  │ FileItem (copied
                       │  dir_path,size,mtime,kind,   │ strings, formatted
                       │  category} — borrows mmap    │ size, kind color)
                       ▼                               ▼
                raw bytes  ─────────────────────►  rendered row
```

The daemon never talks to the GUI. The GUI never talks to the daemon. They
cooperate only by reading and writing the same file. Atomic rename + a fresh
inode (or the Swift app re-mmapping) is the entire synchronization mechanism.

## Live updates

The daemon keeps the index fresh on its own (`src/index/daemon.zig`):

1. **Initial scan**: parallel `getattrlistbulk` walk of `$HOME`, written to
   `index.zst` via `.tmp` + `rename(2)`.
2. **FSEvents watcher**: a `FSEventStream` on `$HOME` posts coalesced events
   to a 2 s-latency callback that bumps a `dirty_count`. The stream is
   created with `kFSEventStreamCreateFlagIgnoreSelf` and an explicit exclusion
   path for the app-support dir, preventing the daemon's own index writes from
   scheduling another rebuild (rebuild-treadmill prevention). The daemon also
   filters events through `config.isPathUnder` as a second layer.
3. **Coalesced rebuild**: every 2 s the CFRunLoop wakes the daemon; when
   `dirty_count ≥ 1000` or 30 s have passed since the last rebuild, it
   re-scans and re-writes the index.
4. **Daily full rescan**: every 24 h the daemon does a full rebuild regardless,
   so it self-heals from any drift.
5. **launchd hosting**: `just install-daemon` writes a plist to
   `~/Library/LaunchAgents/dev.zest.indexer.plist` and `launchctl load`s it.
   The daemon runs as `ProcessType=Background` with `LowPriorityIO` and is
   kept alive by launchd.

The Swift app hot-reloads the index: a 5-second `Timer` in `AppCoordinator`
calls `ZestCore.currentIdentity` to stat the index file and compares inode,
size, and mtime against the open `ZestCore`'s `fileIdentity`. When any field
differs (including the `core == nil` case, i.e. the index didn't exist at
launch), it opens a new `ZestCore` and swaps `core`. Because rows are copied
at the FFI boundary before the swap, existing results remain valid until ARC
releases the old mmap.

## Threading model

- **Indexer (daemon)**: 1 process, 1 thread for FSEvents + run loop,
  8 worker threads for the parallel scan (`max_scan_threads = 8`, measured
  sweet spot on a 12-core machine).
- **Search engine**: synchronous. `searchCancellable` accepts an optional
  atomic `u32` cancel flag; text scans poll it every 64 KiB of candidate
  positions, filter-only scans every 512 entries, and cancellation returns
  `error.SearchCancelled`.
- **Swift UI**: the main thread drives AppKit. Engine queries run on a serial
  `queryQueue` (`DispatchQueue` with `.userInitiated` QoS) in `AppCoordinator`.
  Each state change cancels the previous query's token before enqueuing its own.
  A separate `queryGeneration` counter still guards delivery: the queue closure
  captures the generation and discards the result on main if
  `self.queryGeneration != gen`. `notifyChange` fires `onChange` twice per
  change: once immediately so observers can show a loading state (stale rows
  still visible), and once when the fresh rows land. The sidebar histogram also
  runs off-main on a `DispatchQueue.global(qos: .userInitiated)` task with its
  own `histogramGeneration` guard in `CategorySection`.

## What lives where

```
src/
├── indexer_main.zig        ← daemon entry; delegates to index/daemon.zig
├── zest_core_lib.zig       ← library entry; pulls in capi/zest_core.zig
├── capi/
│   └── zest_core.zig       ← C ABI surface (14 functions + ZestRow/ZestHistogram/ZestExtBreakdown)
├── engine.zig              ← module root re-exporting the pure engine (benchmarks/tools)
├── core/
│   ├── casefold.zig        ← length-preserving UTF-8 case folding (blob + query)
│   ├── casefold_data.zig   ← generated Unicode 17 simple-fold mapping table
│   ├── filters.zig         ← FilterCriterion union (kind/ext/size/date/cat/path)
│   ├── types.zig           ← FileKind, FileCategory enum, FileEntry
│   ├── runtime.zig         ← global Io handle + nowNanos / readFileAlloc helpers
│   ├── humanize.zig        ← "1.2 MB" / "5mo ago" formatting
│   └── file_types.zig      ← extension → FileCategory via StaticStringMap
├── index/
│   ├── format.zig          ← binary on-disk layout (writer)
│   ├── reader.zig          ← reader over the mmap'd bytes
│   ├── search.zig          ← SIMD substring + bitmap intersection + cancellation
│   ├── subtree.zig         ← subtree histogram + ext-breakdown merge
│   ├── builder.zig         ← scan files → columnar index
│   ├── bulk_scan.zig       ← parallel getattrlistbulk walker
│   ├── bitmap.zig          ← sorted-array bitmap (used for category filtering)
│   ├── fsevents.zig        ← thin wrapper over FSEventStream
│   └── daemon.zig          ← scan + watch loop + launchd plist generator
└── config/
    ├── config.zig          ← path constants, name_excludes, path_excludes
    └── user_config.zig     ← ~/.config/zest/config.json

Sources/Zest/
├── App/
│   ├── main.swift          ← NSApplication entry + --snapshot mode
│   ├── AppDelegate.swift   ← main menu (⌘↑ Go Up, ⌘↓ Open Selected)
│   ├── AppCoordinator.swift← single source of truth (path, query, scope, sort,
│   │                         queryQueue + hot-reload timer)
│   └── Snapshot.swift      ← off-screen render to PNG
├── Shell/
│   ├── RootViewController.swift  ← sidebar | split | chrome bands
│   ├── ToolbarView.swift
│   ├── FilterBarView.swift
│   ├── SearchField.swift
│   ├── Breadcrumb.swift
│   ├── StatusBarView.swift
│   └── PlaceholderBand.swift
├── Sidebar/
│   └── SidebarViewController.swift  ← PINNED + CATEGORIES tree
├── Browser/
│   └── BrowserViewController.swift ← NSTableView (5 cols, 34/48pt rows,
│                                     no-index / no-results / empty-folder states)
├── Core/
│   ├── ZestCore.swift      ← mmap + zest_open + query/histogram/ext_breakdown wrappers
│   │                         + FileIdentity inode/size/mtime identity
│   └── UserState.swift     ← pins + folder colors (pins.json / folder_colors.json)
└── Design/
    ├── Theme.swift         ← Darcula dark palette
    ├── Hairline.swift
    └── Category.swift      ← kind/category → icon + tint
```

## Index file lifecycle (one rebuild)

1. **Bulk scan** — 8 worker threads, each pulling directories off a shared
   queue, calling `getattrlistbulk` in batches, and streaming TSV lines into
   their own `.scan.tmp.N` file under `~/Library/Application Support/zest/`.
2. **Builder** — reads the TSV files back (any order), deduplicates paths into
   a directory table, accumulates per-category sorted index lists, and writes
   the columnar layout into a single contiguous `[]u8`.
3. **Atomic write** — writes to `index.zst.tmp` then `rename(2)`s to
   `index.zst`. The inode changes, so any process holding a stale mmap either
   keeps its snapshot (and gets a new one next time it reopens) or remaps
   after the rename. There is no in-process lock.
4. **Mtime / stat** — the file's mtime + size are sufficient for any client
   to decide "the index changed, re-mmap" without parsing the bytes.

## Open questions / known gaps

- **`Zest.app` is unbundled.** `main.swift` calls `NSApplication.shared` +
  `setActivationPolicy(.regular)`. It works but doesn't have a real
  `Info.plist` / app bundle, so Finder metadata, file-association handling,
  and the Dock icon are minimal. A proper bundle would fix that.
- **C ABI error reporting (C8).** `zest_open` returns `null` on any malformed
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

## See also

- [CLAUDE.md](../CLAUDE.md) — build, test, and code conventions.
- [docs/architecture.html](architecture.html) — interactive SVG diagram of
  the same architecture.
