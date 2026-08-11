# Zest

![Zig](https://img.shields.io/badge/lang-Zig_0.16.0-F7A41D?style=flat-square&logo=zig)
![macOS](https://img.shields.io/badge/platform-macOS-000000?style=flat-square&logo=apple)
![MIT License](https://img.shields.io/badge/license-MIT-green?style=flat-square)

A minimal, fast Finder replacement for macOS. The Swift app (`Sources/Zest/`) links a Zig engine (`libzest-core.a`) via C ABI. The `zest-indexer` binary (Zig) runs as a background daemon keeping the search index up to date.

The app opens a native AppKit window backed entirely by the memory-mapped index:

- A **sidebar** of pinned folders (Home, Desktop, Documents, Downloads by default — add your own).
- A **file list** with sortable Name / Size / Date / Type columns and native file icons.
- A **search field** with qualifier filters — `ext:pdf`, `kind:folder`, `size:>1mb`, `category:images`, and `!` negation — that searches the current folder's subtree.
- **View options:** keep folders on top, show full paths, per-folder color tags, open in terminal, pin/unpin, save filters.

Browsing and searching are the same mechanism: every list is a single query against the index.

## Requirements

- macOS (Apple Silicon or Intel)
- Zig 0.16.0
- Xcode command line tools (the build invokes `xcrun` to locate the macOS SDK)

## Build & Run

```sh
zig build                        # Build zest-indexer + libzest-core.a
zig build test                   # Run all Zig tests
swift build                      # Build the Swift app (links libzest-core.a)
```

A `justfile` wraps the common workflows:

```sh
just run            # Build everything + swift run Zest (Debug Swift, ReleaseFast engine)
just run-fast       # Build everything + swift run -c release Zest (Release Swift + engine)
just index          # Build the indexer (ReleaseFast) and scan ~
just test           # Run Zig + Swift tests
```

Run `just run` for day-to-day use — it rebuilds the engine in ReleaseFast (Debug engine is ~19× slower on large indices). Use `just run-fast` for a fully optimized build.

## Search Index

Zest uses a custom binary search index instead of SQLite or Spotlight. The index lives at `~/Library/Application Support/zest/index.zst` and is shared across all zest instances via memory-mapped reads.

### Building the index

```sh
# First-time: build the index for your home directory
zig-out/bin/zest-indexer --full-scan ~

# Or install as a launchd daemon (runs on boot, watches for changes)
zig-out/bin/zest-indexer install
```

The indexer scans the filesystem in parallel using macOS `getattrlistbulk` — a fixed worker pool over a shared directory queue, each worker streaming entries to its own temp file. This is ~6.6× faster than a per-file `stat` walk (a ~5.7M-file home directory scans in ~24s). It skips excluded directories (`.git`, `node_modules`, `__pycache__`, `~/Library/Caches`, `~/Library/Developer`, etc.) and writes a columnar binary file.

### Index lifecycle

```mermaid
graph LR
    subgraph "zest instances (readers)"
        Z1[zest] -->|mmap read-only| IDX
        Z2[zest] -->|mmap read-only| IDX
    end

    subgraph "indexer (writer)"
        FS[FSEvents] -->|dirty paths| D[zest-indexer]
        D -->|write| TMP[index.zst.tmp]
        TMP -->|atomic rename| IDX[index.zst]
    end

    Z1 -.->|stat poll 5s| IDX
```

- **Atomic updates:** The indexer writes to a `.tmp` file, then does an atomic `rename()`. Readers holding the old mmap continue safely — the OS keeps old pages until unmapped.
- **Change detection:** Each zest instance stats the index file every 5 seconds. If the inode changes, it remaps to the new file.
- **FSEvents watcher:** The daemon watches `$HOME` via macOS FSEvents. It coalesces changes and rebuilds when either 1000+ events accumulate or 30 seconds pass since the last event.
- **Daily safety net:** A full rescan runs every 24 hours regardless of events, in case FSEvents misses something.

### Binary format

The index uses a columnar layout designed for fast sequential scanning:

```mermaid
block-beta
    columns 1
    H["Header (64B): magic, version, entry count, column offsets"]
    N["Names Column: offsets[] | lengths[] | name blob | lowercase blob"]
    P["Paths Column: parent_ids[] | dir table (deduplicated)"]
    M["Metadata Column: sizes[] | mtimes[] | kinds[] | categories[]"]
    B["Bitmaps: sorted-array bitmaps per FileCategory"]
```

| Column | Purpose |
|--------|---------|
| **Names** | Two copies of concatenated filenames — original case for display, lowercase for search. Offsets and lengths arrays allow O(1) lookup by entry index. |
| **Paths** | Parent directory IDs pointing into a deduplicated directory table. Most files in a directory share one entry, so path storage is compact. |
| **Metadata** | Parallel arrays of allocated sizes (size on disk), modification times, file kinds (file/dir/symlink), and categories. |
| **Bitmaps** | One sorted array of entry indices per file category (images, code, documents, etc.). Used for fast intersection with search results. |

### How search works

Browsing and searching are one mechanism: the file list is always a single query against the index, parameterized by a **scope** (the current folder) and a **depth**. An empty query lists the folder's direct children (depth 1); typing free text or a qualifier filter (`ext:`, `kind:`, `size:`, `category:`, with `!` negation) searches the whole subtree under the scope. Text matching itself works like this:

```mermaid
sequenceDiagram
    participant User
    participant Search
    participant NameBlob as Lowercase Name Blob
    participant Bitmap as Category Bitmap

    User->>Search: query="invoice", category=documents
    Search->>NameBlob: Scan for "invoice" substring
    Note over NameBlob: First/last char check,<br/>then full memcmp verify
    NameBlob-->>Search: matching byte offsets
    Search->>Search: Binary search offsets → entry IDs
    Search->>Bitmap: AND with documents bitmap
    Bitmap-->>Search: filtered entry IDs
    Search-->>User: results with name, path, size, type
```

1. The query is lowercased, then scanned against the lowercase name blob
2. For each position, a first-char + last-char check provides a fast reject before full `memcmp`
3. Matching byte positions are mapped to entry indices via binary search on the offsets array
4. Category filters intersect with the pre-computed bitmap; other qualifiers (`ext:`, `kind:`, `size:`) match per result
5. **Folder listings** (empty query, depth 1) skip the substring scan: the scope resolves to a directory id and matches the compact parent-id column, so listing a folder in a 5.7M-file index takes ~6ms instead of a full scan
6. Typical text query: ~3–5ms over 1M+ files

### Benchmarking

```sh
just bench-capi "invoice"    # text-search latency against the real index via C ABI
```

`bench-capi` benchmarks `zest_query` (the C ABI call the Swift app makes) against the real index: 1 warmup + 7 samples, median reported. See `benchmarks/bench_capi.zig` for the harness.

## Background Daemon

The `zest-indexer` daemon keeps the index fresh:

```sh
zest-indexer install                    # Install as launchd agent + start
zest-indexer install --binary-path /usr/local/bin/zest-indexer  # Custom path
zest-indexer uninstall                  # Stop + remove launchd agent
zest-indexer --full-scan ~              # One-shot full index build
zest-indexer --full-scan ~/code         # Index a specific subtree
```

When installed, it runs as `dev.zest.indexer` via launchd with `LowPriorityIO` and `Background` process type — minimal impact on system performance.

## File Categories

Zest categorizes files by extension into 8 groups (80+ extensions mapped):

| Category | Extensions |
|----------|-----------|
| Images | png, jpg, gif, webp, svg, heic, bmp, ico, tiff, psd, ... |
| Text | txt, md, rst, log, org, tex |
| Documents | pdf, doc, docx, odt, rtf, pages, epub |
| Spreadsheets | xls, xlsx, csv, ods, numbers, tsv |
| Audio | mp3, wav, aac, flac, ogg, m4a, opus, ... |
| Video | mp4, avi, mov, mkv, webm, ... |
| Code | zig, rs, py, js, ts, go, c, cpp, java, swift, html, css, json, yaml, sh, ... |
| Archives | zip, tar, gz, 7z, rar, zst, dmg, iso, ... |

## Pinned Folders

Default pins: Home, Desktop, Documents, Downloads. Custom pins are persisted to `~/Library/Application Support/zest/pins.json`.

## Architecture

> The current architecture is documented at [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) with a self-contained SVG diagram at [docs/architecture.html](docs/architecture.html). The mermaid block below describes the current architecture: the Swift app links `libzest-core.a` and mmaps the same `index.zst` as the indexer daemon.

```mermaid
graph TB
    subgraph "Zest.app (Swift)"
        SwiftUI[Sources/Zest UI<br/>AppKit windows + views] --> AC[AppCoordinator.swift<br/>query coordinator]
        AC --> ZC[ZestCore.swift<br/>C ABI wrapper]
        ZC --> CAPI[capi/zest_core.zig<br/>C ABI surface]
        CAPI --> IR[reader.zig<br/>O(1) index access]
        CAPI --> Search[search.zig<br/>Scoped queries]
        CAPI --> ST[subtree.zig<br/>O(D) subtree walks]
        IR --> Bitmap[bitmap.zig]
    end

    subgraph "zest-indexer binary"
        Daemon[daemon.zig<br/>Main loop] --> Builder[builder.zig<br/>Scan → columns]
        Builder --> Bulk[bulk_scan.zig<br/>parallel getattrlistbulk]
        Daemon --> FSE[fsevents.zig<br/>macOS FSEvents]
        Builder --> Format[format.zig<br/>Binary format]
    end

    subgraph "Shared"
        Index[(index.zst)]
        Config[config.zig<br/>Paths & excludes]
        Types[types.zig]
        FT[file_types.zig<br/>Extension map]
        Filters[filters.zig<br/>Query parsing + matching]
    end

    IR -.->|mmap read| Index
    Builder -.->|atomic write| Index
    ZC --> Config
    Daemon --> Config
    Search --> Filters
```

### Design decisions

- **No SQLite/Spotlight:** Custom mmap'd format delivers sub-5ms queries. SQLite FTS5 with trigrams is 100-500ms for 1M files.
- **Parallel `getattrlistbulk` scan:** The indexer reads directory metadata in bulk across a worker pool instead of one `stat` per file — ~6.6× faster on a 5.7M-file tree. (Parallelizing the per-file `stat` walk barely helped; the `std.Io` path serializes, while the raw bulk syscall scales.)
- **C ABI engine boundary:** The Swift app links `libzest-core.a` (built by `zig build core -Doptimize=ReleaseFast`) and calls into the Zig engine via a thin C ABI (`capi/zest_core.zig`). All state for a query session lives in an opaque `ZestHandle` pointer; Swift owns the lifetime.
- **Unmanaged ArrayLists:** Zig 0.16 `std.ArrayList` is unmanaged (allocator passed per-call), which we use throughout.
- **Centralized `Io` handle:** Zig 0.16 routes filesystem, clock, and process access through an `Io` instance handed to `main`. We stash it once in `core/runtime.zig` (alongside small `readFileAlloc`/`writeFileAbsolute`/`ensureDir` helpers) rather than threading it through every signature.
- **Deep modules over shallow ones:** Moved subtree computations out of `IndexReader` into `subtree.zig`. Filter parsing lives with `FilterCriterion` in `filters.zig`. Each module earns its keep by concentrating complexity, not just moving it.

## Project Structure

```
Sources/Zest/             # Swift app (AppKit UI + coordination)
├── App/
│   ├── AppCoordinator.swift  # Query coordinator (result caching, filtering, sorting)
│   ├── AppDelegate.swift     # NSApplicationDelegate
│   ├── main.swift            # Entry point
│   └── Snapshot.swift        # Index snapshot value type
├── Core/
│   ├── UserState.swift       # Pins + folder colors persistence (JSON)
│   └── ZestCore.swift        # Swift wrapper over the C ABI
├── Browser/              # File list view controller
├── Sidebar/              # Pinned-folders sidebar
├── Shell/                # Chrome: toolbar, search field, breadcrumb, filter bar, status bar
└── Design/               # Theme, colors, layout constants

src/
├── indexer_main.zig      # Daemon entry point (sets up runtime, delegates to daemon.zig)
├── zest_core_lib.zig     # Library root for libzest-core.a
├── test_root.zig         # Test root importing all modules with embedded tests
├── core/
│   ├── types.zig          # FileKind, FileCategory, FileEntry, Pin, SearchResult, DirListing
│   ├── file_types.zig     # Extension → category mapping (80+ extensions)
│   ├── filters.zig        # Filter criteria (ext/kind/size/date/category/path) + parsing + matching
│   ├── humanize.zig       # Human-friendly size / duration / count formatters
│   └── runtime.zig        # Process-wide Io/env handle + file helpers (Zig 0.16)
├── index/
│   ├── format.zig         # Columnar binary index format (header, columns, write)
│   ├── builder.zig        # Drives the scan, parses results, builds the index
│   ├── bulk_scan.zig      # Parallel macOS getattrlistbulk directory scanner
│   ├── reader.zig         # Read-only O(1) index access (names, paths, metadata, bitmaps)
│   ├── subtree.zig        # O(D) subtree walks (histogram, ext breakdown across directories)
│   ├── search.zig         # Scoped query: substring search, filters, sort, folder listings
│   ├── bitmap.zig         # Sorted-array bitmaps (AND, OR, contains, iterate)
│   ├── fsevents.zig       # FSEvents C interop wrapper
│   └── daemon.zig         # Background indexer: scan, watch, rebuild, launchd
├── capi/
│   └── zest_core.zig      # C ABI over the Zig index engine for the Swift UI
└── config/
    ├── config.zig         # App paths, exclude patterns, directory setup
    └── user_config.zig    # Terminal-candidate resolution

benchmarks/
└── bench_capi.zig         # C ABI regression harness (run with `just bench-capi`)
```

## Testing

Zig tests are embedded in source files as `test` blocks. Swift tests live in `Tests/ZestTests/`.

```sh
zig build test     # Run all Zig tests via src/test_root.zig
swift test         # Run all Swift tests
```

Zig test coverage:
- File type categorization (extensions, dotfiles, compound extensions)
- Query parsing and filter matching (`ext`/`kind`/`size`/`date`/`category`/`path`, negation)
- Bitmap operations (contains, AND intersection, OR union, iteration)
- Index format roundtrip (write → read, all columns) and scan-file parsing
- Search (substring, case-insensitive, qualifier/category filters, scope + depth folder listings, column sort incl. folders-on-top)
- C API (zest_query routing, histogram depth=1 vs subtree, ext_breakdown per-folder and merged)
- Subtree operations (histogram aggregation, ext breakdown merging)
- Config excludes, terminal-candidate resolution, and humanize formatters

Swift test coverage:
- Filter parsing and query matching (ZestTests/FilterTests)
- Theme derivation and color constants (ZestTests/ThemeTests)
- ZestCore C ABI wrapper (ZestTests/ZestCoreTests)
- UserState pins and folder colors persistence (ZestTests/UserStateTests)

The Swift UI layer is exercised by hand, not in the test suite, per project convention.

## License

[MIT](LICENSE)
