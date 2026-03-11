# Zest: Minimal File Browser for macOS

## Context

A minimal, fast Finder replacement in Zig called **Zest**. CLI: `zest .` or `zest /path` opens a GUI at the given path. Features pinnable sidebar, blazing-fast indexed file search with type filtering, and JetBrains Darcula dark theme. macOS only. Native AppKit UI via `zig-objc`.

**Key design principle:** Global shared index — one index serves all zest instances. No Spotlight dependency. Custom mmap'd binary format for sub-10ms query latency.

**Environment:** Zig 0.15.2, macOS Darwin 24.6.0

---

## Project Structure

```
zig-finder/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig                     # CLI entry: `zest .` or `zest /path`
│   ├── app.zig                      # Application controller
│   ├── core/
│   │   ├── types.zig                # FileEntry, FileKind, FileCategory, Pin, etc.
│   │   ├── fs_provider.zig          # FileSystemProvider vtable interface
│   │   ├── real_fs.zig              # Real filesystem implementation
│   │   ├── fake_fs.zig              # In-memory fake for tests
│   │   ├── file_types.zig           # Extension → category (StaticStringMap)
│   │   ├── navigator.zig            # Path navigation with back/forward/up
│   │   └── pins.zig                 # Pin manager (JSON persistence)
│   ├── index/
│   │   ├── format.zig               # Binary index format: header, columns, bitmaps
│   │   ├── builder.zig              # Builds index from filesystem scan
│   │   ├── reader.zig               # Mmap'd read-only index access
│   │   ├── search.zig               # SIMD substring search over name column
│   │   ├── bitmap.zig               # Roaring bitmap impl for category/ext filtering
│   │   ├── fsevents.zig             # FSEvents C interop wrapper
│   │   └── daemon.zig               # Background indexer entry point (zest-indexer)
│   ├── ui/
│   │   ├── theme.zig                # Darcula color constants
│   │   └── appkit.zig               # Native AppKit UI via zig-objc
│   └── config/
│       └── config.zig               # Paths, defaults, exclude patterns
└── test/
    ├── test_file_types.zig
    ├── test_search.zig
    ├── test_bitmap.zig
    ├── test_index_format.zig
    ├── test_pins.zig
    ├── test_navigator.zig
    └── test_integration.zig
```

---

## Index Architecture

### Why Not SQLite

SQLite FTS5 with trigrams: ~100-500ms for 1M files. Custom mmap'd format with SIMD: <5ms. For a file browser, query latency IS the user experience.

### Binary Index Format (`format.zig`)

Single file at `~/Library/Application Support/zest/index.zst`

```
┌─────────────────────────────────────────────────┐
│ Header (64 bytes)                               │
│   magic: u64 (0x5A455354494E4458 = "ZESTINDX") │
│   version: u32                                  │
│   num_entries: u64                              │
│   created_at: u64 (epoch seconds)              │
│   names_offset: u64                            │
│   paths_offset: u64                            │
│   meta_offset: u64                             │
│   bitmap_offset: u64                           │
├─────────────────────────────────────────────────┤
│ Names Column                                    │
│   name_offsets: [num_entries]u32   (byte offset │
│                                     into blob)  │
│   name_lengths: [num_entries]u16                │
│   name_blob: packed concatenated filenames      │
│   (lowercase copy for case-insensitive search)  │
├─────────────────────────────────────────────────┤
│ Paths Column                                    │
│   parent_ids: [num_entries]u32  (index into     │
│                                  dir table)     │
│   dir_table_count: u32                          │
│   dir_offsets: [dir_count]u32                   │
│   dir_blob: concatenated directory paths        │
│   (prefix-deduplicated: most files share dirs)  │
├─────────────────────────────────────────────────┤
│ Metadata Column                                 │
│   sizes: [num_entries]u64                       │
│   mtimes: [num_entries]i64    (epoch seconds)   │
│   kinds: [num_entries]u8      (file/dir/symlink)│
│   categories: [num_entries]u8 (FileCategory)    │
├─────────────────────────────────────────────────┤
│ Roaring Bitmaps (category/extension filters)    │
│   num_bitmaps: u32                              │
│   bitmap_index: [{category, offset, size}]      │
│   bitmap_data: serialized roaring bitmaps       │
│   (one bitmap per FileCategory)                 │
│   (one bitmap per common extension)             │
└─────────────────────────────────────────────────┘
```

### SIMD Substring Search (`search.zig`)

Searches the lowercase name blob using Zig's `@Vector` SIMD:

```
Query: "invoice"
1. Load first char 'i' and last char 'e' into SIMD registers (16 or 32 wide)
2. Scan name_blob 16/32 bytes at a time
3. Compare first char at position P and last char at position P+len-1
4. On match: verify full substring with memcmp
5. Map matching byte offset → entry ID via name_offsets binary search
6. If category filter active: AND with roaring bitmap
7. Return top results
```

**Performance math:** 1M files × ~20 chars avg = 20MB name data. At 16GB/s SIMD throughput = ~1.25ms scan time. With bitmap filtering, typical queries <5ms.

### Roaring Bitmaps (`bitmap.zig`)

Pre-computed bitmaps stored in the index:
- One bitmap per `FileCategory` (images, text, documents, spreadsheets, audio, video, code, archives)
- One bitmap per top-20 extensions (pdf, py, js, ts, json, md, etc.)

Query: "invoice" + category=documents → SIMD scan result ∩ documents_bitmap. Intersection is <1ms even for large sets.

### Global Index Lifecycle

```
zest (UI)  ─── mmap read-only ──┐
zest (UI)  ─── mmap read-only ──┤── ~/Library/Application Support/zest/index.zst
zest (UI)  ─── mmap read-only ──┘
                                      ▲
                                      │ atomic rename
                                      │
                               zest-indexer (launchd agent)
                                 - Watches $HOME via FSEvents
                                 - Builds new index → index.zst.tmp
                                 - Atomic rename: .tmp → index.zst
                                 - Runs on boot via launchd
```

**Atomic updates:** Indexer writes to `.tmp` file, then `rename()` atomically swaps it. Readers holding old mmap continue reading old data safely (OS keeps old pages until unmapped). Readers detect new index via file stat polling (every ~5s) and remap.

**First run:** If no index exists, `zest` triggers `zest-indexer` and shows "Indexing..." with progress. Subsequent launches use the existing index immediately.

### FSEvents Watcher (`fsevents.zig`)

```zig
// C interop via @cImport("CoreServices/CoreServices.h")
// Watch $HOME recursively with 2s coalesce latency
// On events: mark affected directories as dirty
// Every 30s (or on accumulated 1000+ events): rebuild index
```

**Exclusions** (configurable in `~/.config/zest/config.json`):
- `.git`, `node_modules`, `.Trash`, `__pycache__`, `.DS_Store`
- `~/Library/Caches`, `~/Library/Logs`
- Any path matching user-defined glob patterns

### Indexer Process (`daemon.zig`)

Two modes:
1. **Full scan:** Walk entire `$HOME` tree, build complete index. Used on first run or manual reindex.
2. **Incremental:** FSEvents triggers partial rebuild — only rescan dirty directories, merge with existing index.

Launchd plist installed at `~/Library/LaunchAgents/dev.zest.indexer.plist`:
```xml
<dict>
    <key>Label</key><string>dev.zest.indexer</string>
    <key>ProgramArguments</key>
    <array><string>/usr/local/bin/zest-indexer</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>LowPriorityIO</key><true/>
</dict>
```

---

## Core Architecture

### FileSystemProvider (vtable interface)

Same `std.mem.Allocator`-style pattern for testability:

```zig
pub const FileSystemProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        listDir: *const fn (...) Error!DirListing,
        stat: *const fn (...) Error!FileEntry,
        exists: *const fn (...) bool,
        isDir: *const fn (...) bool,
        readFile: *const fn (...) Error![]const u8,
        writeFile: *const fn (...) Error!void,
    };
};
```

Two impls: `RealFs` (wraps `std.fs`) and `FakeFs` (in-memory `StringHashMap`).

### File Type Categories (`file_types.zig`)

`StaticStringMap` mapping ~80 extensions to 8 categories:
- **images**: png, jpg, jpeg, gif, webp, svg, heif, bmp, ico, tiff
- **text**: txt, md, rst, log
- **documents**: pdf, doc, docx, odt, rtf, pages
- **spreadsheets**: xls, xlsx, csv, ods, numbers
- **audio**: mp3, wav, aac, flac, ogg, m4a, wma
- **video**: mp4, avi, mov, mkv, flv, wmv, webm
- **code**: zig, rs, py, js, ts, go, c, h, cpp, java, rb, swift, html, css, json, yaml, toml, sh
- **archives**: zip, tar, gz, 7z, rar, bz2

### App Controller (`app.zig`)

Owns: Navigator, PinManager, IndexReader. UI-agnostic API:
- `openDirectory(path)`, `goBack()`, `goForward()`, `goUp()`
- `search(query, ?category, ?extension)` → `[]SearchResult` (queries the mmap'd index)
- `addPin(path)`, `removePin(path)`
- `getCurrentEntries()`, `getPins()`, `getIndexStatus()`

### Pin Persistence

JSON at `~/Library/Application Support/zest/pins.json`. Defaults: Home, Desktop, Documents, Downloads.

---

## UI Layout (Darcula Theme)

```
+------------------------------------------------------------------+
| [<] [>] [^]  /Users/helge/code/zest             [Search...    ] |  toolbar: #3C3F41
+----------+-------------------------------------------------------+
|          | Name              Size      Modified     Type          |  headers: #3C3F41
| PINNED   +-------------------------------------------------------+
|          | 📁 src/           --        Mar 10       directory     |  list: #2B2B2B
|  Home    | 📁 test/          --        Mar 10       directory     |
|  Desktop | 📄 build.zig      2.1 KB    Mar 10       code          |  selected: #214283
|  Docs    | 📄 README.md      540 B     Mar 9        text          |  hover: #353739
|  Down    |                                                       |
| ──────── |                                                       |  border: #323232
| CUSTOM   |                                                       |
|  Code    |                                                       |  text: #A9B7C6
+----------+-------------------------------------------------------+  secondary: #808080
```

**AppKit Components:**
- `NSSplitView` → sidebar (220px) + main content
- `NSOutlineView` → sidebar pin list
- `NSTableView` → file list (Name, Size, Modified, Type)
- `NSTextField` → search bar in toolbar + path breadcrumb
- `NSPopUpButton` → category filter dropdown
- `NSAppearance` → force dark mode
- Double-click dir → navigate, double-click file → `open`
- Right-click → Pin folder / Copy path

---

## Implementation Phases

### Phase 1: Core Foundation
1. `types.zig` — shared types
2. `file_types.zig` — extension categorization + tests
3. `fs_provider.zig` — vtable interface
4. `fake_fs.zig` — in-memory test impl
5. `real_fs.zig` — OS wrapper
6. `config.zig` — config/data paths, exclude patterns

### Phase 2: Index Engine
7. `format.zig` — binary format definition (header, column layouts, read/write)
8. `bitmap.zig` — roaring bitmap implementation (create, serialize, deserialize, AND/OR)
9. `builder.zig` — walks filesystem, builds index file (columnar + bitmaps)
10. `reader.zig` — mmap reader (open index, access columns, poll for updates)
11. `search.zig` — SIMD substring search over mmap'd name column
12. Tests for format roundtrip, bitmap ops, search correctness

### Phase 3: Background Indexer
13. `fsevents.zig` — FSEvents C interop wrapper
14. `daemon.zig` — indexer main: full scan + incremental FSEvents updates
15. Launchd plist generation / install command
16. Tests for FSEvents event processing

### Phase 4: Core Features
17. `navigator.zig` — path history + tests
18. `pins.zig` — JSON persistence + tests
19. `app.zig` — wire everything: navigator + pins + index reader
20. `main.zig` — CLI entry point, arg parsing

### Phase 5: UI (AppKit)
21. `theme.zig` — Darcula constants
22. `appkit.zig` — window + toolbar + file list via zig-objc
23. Sidebar with pins (NSSplitView + NSOutlineView)
24. Search bar → queries index reader → displays results
25. Category filter dropdown
26. Context menus, keyboard shortcuts, polish

---

## Build Configuration

Two binaries from one project:

```zig
// build.zig
// Binary 1: zest (GUI app)
const zest = b.addExecutable(.{ .name = "zest", .root_source_file = b.path("src/main.zig"), ... });
zest.linkFramework("AppKit");
zest.linkFramework("CoreServices");

// Binary 2: zest-indexer (background daemon)
const indexer = b.addExecutable(.{ .name = "zest-indexer", .root_source_file = b.path("src/index/daemon.zig"), ... });
indexer.linkFramework("CoreServices");  // for FSEvents
indexer.linkLibC();  // for mmap, posix

// Both link zig-objc for ObjC interop where needed
```

**Dependencies:** `zig-objc` (ObjC bridge), system `CoreServices` + `AppKit` frameworks.

---

## Testing Strategy

All core + index tests use FakeFs and in-memory buffers — no real FS, no UI.

- **file_types**: every category, edge cases (no ext, `.tar.gz`, dotfiles)
- **bitmap**: roaring create/serialize/deserialize, AND intersection, OR union, iteration
- **format**: build index from known data → mmap → verify columns read back correctly
- **search**: SIMD substring correctness, case-insensitive, empty query, no matches, max results
- **search + bitmap**: combined query + category filter
- **pins**: JSON roundtrip, add/remove/reorder, malformed JSON, defaults
- **navigator**: back/forward/up, root boundary, stack clearing
- **integration**: full workflow with FakeFs (build index → search → filter)

Run: `zig build test`

---

## Performance Targets

| Operation | Target | Technique |
|-----------|--------|-----------|
| Full index build (1M files) | < 30s | Parallel walk, batch writes |
| Incremental update (100 files) | < 1s | Dirty-dir rescan, atomic swap |
| Substring search (1M files) | < 5ms | SIMD scan over mmap'd name column |
| Category filter | < 1ms | Roaring bitmap intersection |
| Combined search + filter | < 10ms | SIMD scan → bitmap AND |
| Index file size (1M files) | ~100-200MB | Columnar, prefix-deduped paths |
| Memory (query process) | < 50MB working set | mmap lazy-loads only accessed pages |
| Index detection / remap | < 5s latency | Stat polling every 5s |

---

## Risks

| Risk | Mitigation |
|------|-----------|
| zig-objc incompatible with Zig 0.15.2 | Test immediately in Phase 5; fork + patch if needed |
| Roaring bitmap impl complexity | Start with simple sorted-array bitmaps; optimize to roaring later if needed |
| SIMD portability (ARM vs x86) | Zig's @Vector abstracts over both; test on Apple Silicon |
| Atomic rename not picked up by readers | Stat polling detects inode change; fallback: manual refresh |
| Index too large for big home dirs | Exclude patterns reduce scope; compress paths with prefix dedup |
| FSEvents misses events | Periodic full rescan (e.g., daily) as safety net |

---

## Verification

1. **Build**: `zig build` produces `zest` and `zest-indexer` binaries
2. **Core tests**: `zig build test` — all pass without UI or real FS
3. **Index build**: `zest-indexer --full-scan ~` builds index file, inspect size
4. **Search perf**: `zest --benchmark "foo"` runs 1000 queries, prints p50/p99 latency
5. **Launch**: `zest .` opens window showing current dir contents
6. **Search**: type query → results appear instantly; filter by category
7. **Navigation**: click dirs, back/forward/up all work
8. **Pins**: defaults visible; add custom pin; persists across restart
9. **Live index**: create file → within 30s appears in search results
10. **Dark mode**: Darcula colors applied regardless of system appearance
