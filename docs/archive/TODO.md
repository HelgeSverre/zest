# Zest — Progress & Task Tracker

## Phase 1: Core Foundation — COMPLETE

- [x] `types.zig` — FileEntry, FileKind, FileCategory, Pin, DirListing
- [x] `file_types.zig` — 80+ extension → category mappings (StaticStringMap)
- [x] `fs_provider.zig` — Vtable interface (allocator-pattern)
- [x] `fake_fs.zig` — In-memory FS for testing
- [x] `real_fs.zig` — OS filesystem wrapper
- [x] `config.zig` — Paths, exclude patterns, app support dir

## Phase 2: Index Engine — COMPLETE

- [x] `format.zig` — Binary columnar format (header, names column, paths column, metadata, bitmaps)
- [x] `bitmap.zig` — Sorted-array bitmaps (AND, OR, contains, iterator)
- [x] `builder.zig` — Recursive filesystem walker → index file
- [x] `reader.zig` — Read-only index access (getName, getDirPath, getMeta, getCategoryBitmaps)
- [x] `search.zig` — First/last char substring search with bitmap category filtering
- [x] Tests: format roundtrip, bitmap ops, reader roundtrip, search correctness, case-insensitive, category filter

## Phase 3: Background Indexer — COMPLETE

- [x] `fsevents.zig` — FSEvents C interop wrapper (stream create, start, stop, callback)
- [x] `daemon.zig` — Full scan mode with atomic rename (.tmp → .zst)
- [x] `daemon.zig` — Launchd plist generation
- [x] **T1: FSEvents watcher loop** — CFRunLoop-based watcher, rebuilds on 1000+ events or 30s timer *(Sprint 1)*
- [x] **T2: Launchd install command** — `zest-indexer install/uninstall` with `--binary-path` override *(Sprint 1)*
- [x] **T3: Periodic full rescan** — 24h safety net timer in watcher loop

## Phase 4: Core Features — COMPLETE

- [x] `navigator.zig` — Back/forward/up with history (tested)
- [x] `pins.zig` — JSON persistence, defaults, add/remove (tested)
- [x] `app.zig` — Wires navigator + pins + index reader + search
- [x] `main.zig` — CLI entry, arg parsing, directory listing
- [x] **T4: Index stat polling** — Checks inode every 5s, auto-reloads on change
- [x] **T5: Human-readable file sizes** — "2.1 KB", "540 B", "3.4 MB" via `formatSizeHuman` *(Sprint 1)*
- [x] **T6: `--benchmark` flag** — 1000 iterations, sorted latencies, p50/p99 in µs *(Sprint 1)*
- [x] **T7: `open` files/dirs** — `openFile` (macOS `open`) + `openInTerminal` (`open -a Terminal`)

## Phase 5: UI (AppKit) — IN PROGRESS

- [x] `theme.zig` — Full Darcula color constants (backgrounds, selection, text, category colors, window dims)
- [x] **T8: ObjC runtime bridge** — `objc.zig` with typed msgSend wrappers, NSString helpers, 4 tests *(Sprint 1)*
- [x] **T9: Window + toolbar** — NSWindow, dark appearance, back/forward/up buttons, path display, search field
- [x] **T10: File list (NSTableView)** — Name, Size, Type columns; sort dirs first; double-click to open/navigate
- [x] **T11: Sidebar (NSSplitView + NSTableView)** — Pinned folders, click to navigate
- [x] **T12: Search bar → index query** — NSSearchField → app.search() → display results in table
- [x] **T13: Category filter dropdown** — NSPopUpButton with FileCategory options
- [x] **T14: Context menus** — Right-click: Open, Open in Terminal, Pin folder, Copy path
- [x] **T15: Keyboard shortcuts** — Cmd+[ (back), Cmd+] (forward), Cmd+Q (quit), Cmd+W (close)
- [ ] **T16: File icons** — NSWorkspace icons or emoji-based per category (currently emoji only)

## Polish & Extras

- [ ] **T17: Exclude pattern config** — Load user globs from `~/.config/zest/config.json`
- [ ] **T18: Sort options** — Click column headers to sort by name/size/date/type
- [ ] **T19: Breadcrumb path bar** — Clickable path segments in toolbar
- [ ] **T20: Drag & drop** — Drag files from zest to other apps
- [ ] **T21: True SIMD search** — Replace scalar first/last char scan with `@Vector` SIMD
- [ ] **T22: Roaring bitmap upgrade** — Replace sorted arrays with compressed roaring for large indexes

---

## Parallelization Analysis

Tasks are grouped by dependency. Tasks within the same group can be worked on simultaneously.

### Independent tracks (fully parallel)

| Track | Tasks | Description |
|-------|-------|-------------|
| **A: Index lifecycle** | T1, T3, T4 | FSEvents loop, periodic rescan, stat polling — all about keeping the index fresh |
| **B: CLI polish** | T5, T6, T17 | Human sizes, benchmark flag, config loading — no UI dependency |
| **C: AppKit foundation** | T8, T9 | ObjC bridge + window creation — must be done before T10–T16 |
| **D: Launchd** | T2 | Install/uninstall command — standalone |

### Sequential dependencies

```
T8 (ObjC bridge) → T9 (window) → T10 (file list) ─┐
                                 → T11 (sidebar)   ─┤→ T14 (context menus)
                                 → T12 (search bar) ┤→ T15 (keyboard shortcuts)
                                 → T13 (filter)     ┘→ T16 (icons)
                                                      → T18 (sort)
                                                      → T19 (breadcrumb)
                                                      → T20 (drag & drop)

T1 (FSEvents loop) → T3 (periodic rescan)
```

### Recommended parallel execution plan

**Sprint 1** — 4 parallel tracks:
- Track A: T1 (FSEvents watcher loop)
- Track B: T5 (human-readable sizes) + T6 (benchmark flag)
- Track C: T8 (ObjC runtime bridge)
- Track D: T2 (launchd install command)

**Sprint 2** — 3 parallel tracks:
- Track A: T3 (periodic rescan) + T4 (stat polling)
- Track C: T9 (window + toolbar) + T10 (file list) + T11 (sidebar)
- Track B: T17 (config loading)

**Sprint 3** — UI wiring (mostly sequential):
- T12 (search bar) + T13 (category filter) + T7 (open files)

**Sprint 4** — Polish (parallel):
- T14 (context menus) | T15 (keyboard shortcuts) | T16 (icons) | T18 (sort)

**Sprint 5** — Advanced (parallel):
- T19 (breadcrumb) | T20 (drag & drop) | T21 (SIMD) | T22 (roaring bitmaps)
