# Zest GUI Redesign — Design & Architecture Spec (v2)

**Date:** 2026-06-06
**Status:** Approved direction + foundation + stack; pending implementation plan
**Stack decision:** **Swift AppKit UI + Zig core via a C ABI** (engine stays Zig)
**Visual + behavior reference (golden):** `prototypes/zest-redesignv2.html` (interactive, resizable; dark+light; deep-links `?mode=` `?accent=` `?theme=` `?path=` `?expand=` `?dialog=`)
**Captures:** `prototypes/v2-*.png`, `prototypes/v2b-*.png`, `prototypes/v2c-*.png`
**Amended by §15 (prototype-v2 fold-in).** (v1 `zest-redesign.html` kept for reference.)

> Ground-up rebuild of the UI as a **Swift AppKit app** linking the existing Zig
> engine as a **C-ABI static library**. Built in parallel and swapped at parity.
> The index/search/daemon engine is untouched; we add a thin C wrapper over it.

---

## 1. Decisions locked

| Decision | Choice |
|---|---|
| Visual direction | Bespoke pro browser — same layout (toolbar · sidebar · list), Linear/Things polish |
| Identity | Fixed **Ink graphite** base + **one derived accent**; default **Lime**, source `auto` (=`NSColor.controlAccentColor`) / preset / hex |
| Scope | Full reimagine of views + behavior. **No** preview pane, **no** command palette |
| Layout foundation | **AppKit + Auto Layout** (`NSStackView` + `NSLayoutAnchor`) + **custom-drawn `NSView`s**; `NSSplitViewController` for the split |
| **UI stack** | **Swift** app (+ optional SwiftUI islands) ↔ **Zig** core via **C ABI** |
| Rebuild strategy | Ground-up parallel; swap at parity |
| Engine | Untouched Zig (index reader, SIMD search, navigator, pins, filters, daemon) |

---

## 2. Why the current UI is janky (root cause)

Two compounding causes:

1. **No layout system.** `window.zig:buildToolbarView` freezes positions with hand
   math (`search_x = popup_x - gap - search_width`) and pins views with autoresizing
   masks. On resize the relationships break → search/Saved drift off-screen, the
   `NSPopUpButton` menu anchors to a stale frame → **dropdown floats off-page**.
2. **AppKit through `objc.msgSend` from Zig.** Every control, constraint, custom view
   subclass, and draw override is hand-bridged with selector strings and manual
   memory management — verbose and fragile, which is why it rots.

The Swift + Zig-core split fixes both: Auto Layout via `NSSplitViewController` /
`NSStackView` / anchors makes drift structurally impossible, and Swift removes the
bridge tax so custom views/drawing stay maintainable.

---

## 3. Target architecture

### 3.1 Build targets

```
┌──────────────────────────┐     C ABI      ┌───────────────────────────┐
│  zest  (Swift .app)       │ ─────────────▶ │  libzest-core.a (Zig)      │
│  AppKit shell + SwiftUI   │  zest_core.h    │  index reader · search     │
│  islands; owns the window │ ◀───────────── │  navigator · pins · filters│
└──────────────────────────┘   ZestRow[]      └───────────────────────────┘
                                                        ▲ Zig import (no FFI)
                                               ┌────────┴───────────────────┐
                                               │  zest-indexer (Zig binary)  │
                                               │  FSEvents daemon, builder   │
                                               └─────────────────────────────┘
```

- **`zest-core`** — new Zig static library exposing a C ABI. Wraps the existing
  `IndexReader`, `search`, `Navigator`, `PinManager`, `FilterStore`, `query_parser`,
  `config`. Internals unchanged; the wrapper is a new `src/capi/zest_core.zig`.
- **`zest`** — the Swift AppKit application. Links `libzest-core.a`, imports
  `zest_core.h`. Owns the window, UI, concurrency, and `zest /path` argv handling.
- **`zest-indexer`** — unchanged Zig binary; keeps using the core via normal Zig
  imports (no FFI), since it's same-language.

### 3.2 The C ABI seam (`src/capi/zest_core.zig` → `include/zest_core.h`)

Hand-written header (stable, explicit — don't rely on `-femit-h`). Representative
surface:

```c
// ---- value types (borrow into the held snapshot's mmap; copy at the boundary) ----
typedef struct { const char *ptr; size_t len; } ZestStr;     // NOT null-terminated
typedef struct {
    ZestStr   name;
    ZestStr   dir_path;
    uint64_t  size;
    int64_t   mtime;      // unix seconds
    uint8_t   kind;       // 0 file, 1 dir, 2 symlink
    uint8_t   category;   // FileCategory enum
} ZestRow;

// ---- lifecycle ----
typedef struct ZestCore  ZestCore;     // opaque; holds the current index snapshot
typedef struct ZestQuery ZestQuery;    // opaque; owns a result buffer + a snapshot ref

ZestCore *zest_open(const char *index_path);   // mmap + ref-count the index
void      zest_close(ZestCore *);
bool      zest_reload_if_changed(ZestCore *);   // inode poll → swap snapshot

// ---- query (synchronous, read-reentrant; Swift runs it off-main) ----
ZestQuery *zest_query(ZestCore *, const char *query_utf8,
                      const char *scope_root,     // "" = whole index ("Everywhere")
                      uint32_t max_depth,          // 1 = folder listing, MAX = subtree
                      uint32_t max_results,
                      uint8_t sort_column, bool ascending);
size_t    zest_query_count(const ZestQuery *);
ZestRow   zest_query_row(const ZestQuery *, size_t i);  // ptr valid until zest_query_free
void      zest_query_free(ZestQuery *);                 // releases buffer + snapshot ref

// ---- category histogram (NEW: scope-aware aggregation for the sidebar tree) ----
typedef struct ZestHistogram ZestHistogram;
typedef struct { uint8_t category; uint32_t count; } ZestCatCount;
typedef struct { ZestStr ext; uint32_t count; } ZestExtCount;
ZestHistogram *zest_histogram(ZestCore *, const char *scope_root, uint32_t max_depth);
size_t        zest_histogram_cats(const ZestHistogram *);
ZestCatCount  zest_histogram_cat(const ZestHistogram *, size_t i);
size_t        zest_histogram_exts(const ZestHistogram *, uint8_t category);   // lazy: on expand
ZestExtCount  zest_histogram_ext(const ZestHistogram *, uint8_t category, size_t i);
void          zest_histogram_free(ZestHistogram *);

// ---- pins / saved filters / folder colors / config (thin pass-throughs) ----
size_t    zest_pins_count(ZestCore *);
ZestRow   zest_pin(ZestCore *, size_t i);                       // name + path
bool      zest_pin_add(ZestCore *, const char *name, const char *path);
void      zest_pin_remove(ZestCore *, const char *path);
// saved filters — manager-window CRUD, backed by FilterStore
size_t    zest_filters_count(ZestCore *);
ZestRow   zest_filter(ZestCore *, size_t i);                    // name + query
bool      zest_filter_upsert(ZestCore *, size_t i, const char *name, const char *query); // i==SIZE_MAX → add
void      zest_filter_remove(ZestCore *, size_t i);
// folder colors — breadcrumb + row tinting (returns false when unset)
bool      zest_folder_color(ZestCore *, const char *path, uint8_t *r, uint8_t *g, uint8_t *b);
```

**Ownership & lifetime (the important part):**
- A `ZestQuery` **retains an `IndexSnapshot` ref** for its whole lifetime, so the
  rows' `ZestStr` pointers (which borrow directly into the mmap'd name/path blobs)
  stay valid until `zest_query_free`. This reuses the existing ref-counting exactly.
- **Strings cross as `{ptr,len}`** (Zig slices aren't null-terminated). Swift copies
  what it displays into `String(decoding:as:)` at the boundary — recommended: **copy
  on read**, so Swift never holds a dangling borrow and can free the query promptly.
- All allocation is Zig-side; Swift must pair every `zest_query` with `zest_query_free`
  (RAII wrapper in Swift, §9).

### 3.3 Swift app structure (`Sources/`)

```
Sources/
  App/         main.swift, AppDelegate.swift           — argv (`zest /path`), NSApplication
  Core/        ZestCore.swift                          — Swift wrapper over zest_core.h (RAII, String marshaling)
  Design/      Theme.swift, Hairline.swift, RoundedPanel.swift, IconButton.swift, PillButton.swift
  Shell/       RootViewController.swift, ToolbarView.swift, FilterBarView.swift, StatusBarView.swift, ScopeControl.swift, SearchBox.swift, Breadcrumb.swift, Dropdown.swift, Chip.swift
  Sidebar/     SidebarViewController.swift, SidebarItem.swift
  Browser/     BrowserViewController.swift, BrowserModel.swift, BrowserSnapshot.swift, FileItem.swift, FileRowView.swift, FileCellView.swift, HeaderView.swift
  Command/     AppCommand.swift, CommandRouter.swift
  Islands/     (SwiftUI) SettingsView.swift, CommandPalette.swift, AboutView.swift   — via NSHostingController
```

(Mirrors the layout in the architecture proposal, plus `Core/` for the FFI wrapper.)

### 3.4 Build orchestration

- `build.zig` builds **`libzest-core.a`** + **`zest-indexer`** (and keeps tests).
- A **SwiftPM package** (`Package.swift`) builds the `zest` app, with a `systemLibrary`
  / `unsafeFlags` target linking `libzest-core.a` and exposing `zest_core.h` via a
  module map. *(Recommended over an `.xcodeproj` — CLI-first, fits `zig build` + `just`.)*
- `justfile` ties them: `just build` → `zig build` (lib + indexer) → `swift build`
  (app). *Open decision §13.*

---

## 4. Design tokens (`Design/Theme.swift`)

Same values as the prototype (Ink graphite + derived accent). One base accent →
derived family, so it can follow the system accent.

### 4.1 Neutrals (fixed Ink)
`background #0F1115` · `panel #16191E` · `panelElevated #1F242A` · `hover #20252B` ·
`border #272C33` · `borderSoft #1D2127` · `text #E9ECEF` · `textSecondary #868E99` ·
`textTertiary #565E68`.

### 4.2 Accent — one base hue, theme-shifted, family derived
Two layers (prototype v2): **`accentBase`** = the chosen hue (default lime `#B8FF3C`), and
**`accent`** = the *effective* color the UI draws with.
- **Dark:** `accent = accentBase`.
- **Light:** `accent = mix(accentBase, .black, ~0.42)` — darken the hue so it keeps real
  contrast on white (bright neon accents are unusable as text/rails on light).

Family derived from the **effective** `accent`: `accentHi = mix(accent, .white, .22)` ·
`accentSoft = accent.alpha(.13)` · `accentLine = accent.alpha(.55)` · `glow = accent.alpha(.16)`.
`onAccent` = **light → `.white`** (effective accent is dark) · **dark →
`accentBase.luminance > .6 ? #0C0E12 : .white`**. Derive perceptually (mix in OKLCH/P3,
mirroring the prototype's `color-mix(in oklch …)`).
Source: config `appearance.accent` = `auto` (→ `NSColor.controlAccentColor`) | preset | hex.

### 4.3 Category colors (fixed)
folder `#6E9BE0` · code `#46C26A` · images `#E0A3FF` · documents `#C9A2FF` ·
text `#9AA4B0` · audio `#FF8CC8` · video `#FF7B72` · spreadsheets `#3FC9A0` · archives `#8C95A0`.

### 4.4 Type & metrics
UI `NSFont.systemFont(13)`; data `NSFont.monospacedSystemFont(11/12)`; header 11.
window 1180×760 (min 800×600) · sidebar 190–260 (`NSSplitViewItem` thickness) ·
toolbar 58 · filter bar 42 · status bar 28 · row 34 / 48 (two-line) · radius 8 ·
`hairline = 1/backingScaleFactor` · traffic-light inset 88.

### 4.5 Theming (dark + light)
The whole palette is tokens, so **dark and light are a token flip** (prototype v2 proves
it). Light overrides the neutrals + semantic surfaces (`sheen`, `scrim`, `grainOpacity`,
`shadowWin/Pop/Dialog`, desktop bg) and darkens the effective accent (§4.2). A
`Design/ThemeManager` resolves tokens from `appearance.theme` = `auto` (follow
`NSApp.effectiveAppearance`) | `dark` | `light`, and re-resolves on appearance change.
Category colors are theme-independent. Tokenize beyond the neutrals: add `sheen`,
`scrim`, `grainOpacity`, `shadowWin/Pop/Dialog`.

---

## 5. UI skeleton (AppKit view tree)

🟢 native does it · 🟡 compose · 🔴 custom-drawn.

```
NSWindow [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView]   App/        🟢
  titleVisibility=.hidden, titlebarAppearsTransparent=true, movableByBackground
└─ RootViewController.view                                                     Shell/      🟡
   ├─ NSVisualEffectView (.underWindowBackground, .behindWindow) — full bleed   Shell/      🟢
   └─ vertical NSStackView (spacing 0, fills)                                   Shell/      🟢
      ├─ ToolbarView (h 58)                                                     Shell/      🔴
      │   └─ hstack(inset left:88): [‹ › ↑ IconButtons] [Breadcrumb] [spacer] [SearchBox flex, minW 200] [Dropdown "Saved"]
      ├─ HairlineView                                                                       🔴
      ├─ FilterBarView (h 42)                                                   Shell/      🔴
      │   └─ hstack: [ScopeControl] [Chips (scroll)] [spacer] [count] [SortButton]
      ├─ HairlineView
      ├─ NSSplitViewController.view (flex)                                      App/        🟢
      │   ├─ NSSplitViewItem(sidebar: SidebarVC)  thickness 190–260            Sidebar/    🟡
      │   └─ NSSplitViewItem(BrowserVC)                                         Browser/    🟡
      │       └─ NSScrollView → NSTableView (view-based, headerView=HeaderView)
      │           ├─ FileRowView (selection draw)                              Browser/    🔴
      │           └─ FileCellView per column                                   Browser/    🔴
      ├─ HairlineView
      └─ StatusBarView (h 28)                                                   Shell/      🔴
```

`NSSplitViewController` gives sidebar collapse/restore + min/max thickness for free —
replaces the hand-managed `NSSplitView` + constraint delegate we have today.

---

## 6. Behavior & flow

### 6.1 Query model (through the FFI)

The list is **one query**; depth decides browse vs search. `BrowserModel` (Swift,
`@MainActor`) calls `ZestCore.query(...)` **off-main**, builds a `BrowserSnapshot`,
delivers it to the table on main.

| Scope (segmented) | scope_root | max_depth | Rows |
|---|---|---|---|
| This folder (default) | current path | 1 | one-line |
| Subfolders | current path | MAX | two-line (name + path) |
| Everywhere | `""` | MAX | two-line |

### 6.2 Command model (replaces scattered selectors)

```swift
enum AppCommand { case goBack, goForward, goUp, focusSearch, toggleSidebar,
                  selectNext, selectPrevious, openSelection, revealInFinder,
                  copyPath, openInTerminal, setScope(Scope), removeFilter(Int) }
```
Routed through `CommandRouter` + the responder chain; key equivalents in the main
menu; `keyDown` in the table for ↑/↓/Return. One place to reason about input.

### 6.3 Event → action (engine reuse via FFI)

| Trigger | Calls | Action |
|---|---|---|
| Back/Fwd/Up | navigator (FFI) | navigate → re-query |
| Breadcrumb edit / click | navigator | open dir |
| Type in search (debounce 150ms) | `query_parser` (in `zest_query`) | re-query; commit `key:value ` → Chip |
| Remove chip / token | rewrite query string | re-query |
| Scope click | — | set root+depth → re-query |
| Saved filter pick/save | filter store (FFI) | set / persist |
| Sidebar pin click | pins (FFI) | open pin |
| Header click | sort args to `zest_query` | re-query sorted |
| Row select | — | update status summary |
| Double-click / Return | open | `NSWorkspace.open` (dir → navigate) |
| Right-click | — | context menu (copy path / terminal / pin / color) |
| ⌘⇧P | — | absolute vs relative names |
| 5s poll | `zest_reload_if_changed` | refresh + status freshness |

### 6.4 States
Browse · Search (two-line) · No results (centered + clear) · Loading (filter-bar
indicator while the off-main query runs) · No index (icon + copy +
`zest-indexer --full-scan ~` pill).

---

## 7. Row rendering (`Browser/FileRowView` + `FileCellView`)

Columns (v2): **Name · Size · Modified · Kind · Ext**.

```
┌ row (34 / 48) ─────────────────────────────────────────────────────────────────────┐
│ [icon 18²] filename        Size    2026-01-01  5mo ago    ● Kind     ext             │
│            project/…/leaf  (mono)  (date mono · timeago dim)  (dot+label)  (mono)    │ ← search
└──────────────────────────────────────────────────────────────────────────────────────┘
```
- Filename never middle-truncates; search rows add the dimmed mono path line (project root + leaf).
- `tableView(_:heightOfRow:)` → 34/48 from the §6.1 flag.
- **Size:** dirs **"N items"** dim / files mono. **Modified:** ISO `YYYY-MM-DD` (mono) + a
  dimmer relative `5mo ago` (computed from `mtime` in Swift), baseline-aligned. **Kind:**
  dot + label (category color); `kind==dir` → "Folder". **Ext:** mono dim, `—` for folders.
- Selection: `FileRowView.draw` paints `accentSoft` fill + 3pt `accent` rail
  (`selectionHighlightStyle = .none`).
- Icons via `NSImage(systemSymbolName:)` tinted by category.

---

## 8. Hardening — acceptance criteria

**Resize/overflow** (prototype already passes — `shot-narrow-search.png`):
no overlap/clipping 800×600 ↔ 2560×1600 · search flexes, `minWidth 200` · Saved+sort
pinned trailing · breadcrumb head-truncates first · chips scroll · `Dropdown` clamps
inside window, Esc/outside dismiss · sidebar 190–260 enforced.

**Focus/input:** full keyboard reachability + tab order; focus ring `accentLine`+`glow`;
typing debounced; no relayout per keystroke.

**FFI/threading:** every `zest_query` paired with `zest_query_free` (zero leaks under
`leaks`/Instruments); queries run **off the main thread**, no UI stall; Swift never
holds a `ZestStr` past `zest_query_free`.

**Perf:** 60fps over 100k rows (NSTableView virtualization); two-line/one-line share baseline; pixel-match the prototype.

---

## 9. FFI wrapper & threading (`Core/ZestCore.swift`)

A safe Swift veneer so the rest of the app never touches raw C:

```swift
final class ZestCore {
    private let handle: OpaquePointer            // ZestCore*
    init?(indexPath: String) { … zest_open … }
    deinit { zest_close(handle) }

    struct Row { let name: String; let dirPath: String; let size: UInt64
                 let mtime: Int64; let kind: Kind; let category: Category }

    // runs synchronously in Zig; callers dispatch to a background queue
    func query(_ q: String, scope: Scope, sort: SortState, limit: Int = 100_000) -> [Row] {
        let qp = zest_query(handle, q, scope.root, scope.maxDepth, UInt32(limit),
                            sort.column.raw, sort.ascending)
        defer { zest_query_free(qp) }                 // RAII: borrow ends here
        return (0..<zest_query_count(qp)).map { i in
            let r = zest_query_row(qp, i)
            return Row(name: r.name.string, dirPath: r.dir_path.string, …)   // COPY at boundary
        }
    }
}
extension ZestStr { var string: String { String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self) } }
```

`BrowserModel` calls `query` on a background `DispatchQueue`/`Task`, then hops to
`@MainActor` to publish a `BrowserSnapshot` and `reloadData`. This replaces the Zig
`async_search` + `NSTimer` debounce machinery (now Swift-side: a coalescing `Task`).

---

## 10. Component → code map

| Prototype piece | Swift | Zig core call |
|---|---|---|
| Palette + accent | `Design/Theme.swift` | `appearance.accent` config (FFI) |
| Window + bands + split | `App/`, `Shell/RootViewController` | — |
| Toolbar / breadcrumb / Saved | `Shell/ToolbarView`,`Breadcrumb`,`Dropdown` | navigator, filter store |
| Search + tokens | `Shell/SearchBox`,`Chip` | `query_parser` (inside `zest_query`) |
| Scope / filter bar / sort | `Shell/FilterBarView`,`ScopeControl` | `zest_query(scope,depth,sort)` |
| Two-line rows + kind pill | `Browser/FileRowView`,`FileCellView` | `zest_query_row` |
| Sidebar | `Sidebar/*` | pins, folder colors |
| Status / empty / loading | `Shell/StatusBarView`, states | `zest_reload_if_changed` |
| Settings / palette (islands) | `Islands/*` (SwiftUI via `NSHostingController`) | config |

Engine internals (index, search, builder, daemon, bitmap, fsevents) — **untouched**.

---

## 11. Verification loop

1. Build (`just build`) → run `zest .`.
2. Screenshot the running app incl. a **narrow** window.
3. Compare to prototype deep-links: `?mode=browse`, `?mode=search`, `?mode=empty`,
   `?accent=…`, 708px resize.
4. Clear §8 criteria (visual + leaks + no main-thread stall) before a region is done.

(No automated UI tests; Zig-core gets normal Zig `FakeFs` unit tests for the C wrapper.)

---

## 12. Build order (ground-up parallel, Swift)

- **P0 — Seam + shell skeleton.** `zest_core.zig` C ABI + `zest_core.h` (open/close,
  `zest_query` over the existing reader); `Package.swift` links the lib; a Swift
  window appears; `Theme`, `Hairline`, `RoundedPanel`. *Checkpoint: Swift calls Zig,
  prints a real query count.*
- **P1 — Make the screenshot real (fake data).** Toolbar, filter bar,
  `NSSplitViewController`, sidebar, table, status bar — all static. *Checkpoint:
  resize/overflow §8 passes.*
- **P2 — Rows.** `FileRowView`/`FileCellView` two-line, kind pill, item-count, accent
  selection.
- **P3 — Wire FFI.** `ZestCore` wrapper + `BrowserModel`/snapshot; real queries,
  scope, search+tokens, sort, debounce off-main. *Checkpoint: leaks clean.*
- **P4 — Sidebar + states.** Pins via FFI, status freshness, empty/loading/no-results.
- **P5 — Input + extras.** Command model, menus/key-equivalents, context menus,
  drag/drop; SwiftUI islands (settings, command palette).
- **P6 — Swap.** `zest` ships as the Swift app; delete `src/ui/*` and the Zig
  `async_search`; `build.zig` now emits `libzest-core.a` + `zest-indexer` only.

---

## 13. Open decisions (confirm)

1. **Build orchestration** — SwiftPM `Package.swift` + `justfile` (rec) vs `.xcodeproj`.
2. **App packaging** — non-bundled executable preserving `zest /path` argv (rec; set
   `activationPolicy = .regular` as today) vs a proper `.app` bundle + launcher.
3. **Min macOS target / Swift version** — propose macOS 13+ / Swift 5.9+ (confirm).
4. **FFI strings** — copy at the boundary (rec, safe) vs borrow + explicit free.
5. **Design confirmations** (carry over): status bar in · folder Size = "N items" ·
   breadcrumb-that-edits · Categories group phase 2 · default accent Lime (`auto` available).
6. Keep the old Zig `src/ui/*` as reference until P6 swap (rec) vs delete up front.
7. **Default theme** — `auto` (follow macOS appearance) vs ship dark-default. (Rec `auto`.)
8. **Category histogram cost** — aggregating category/extension counts over a deep scope
   touches many entries. Reuse the category bitmaps (cheap), tally extensions only on
   expand, bound to top-N, compute off-main. Confirm the budget.
9. **Light-accent darkening ratio** — confirm ~0.42 toward black (§4.2); tune per accent.

## 14. Out of scope
Preview/detail pane · command-palette-as-primary-nav · gallery/Miller views ·
multi-window · iCloud/remote volumes. *(Light mode is now **in scope** — §4.5.)*

---

## 15. Prototype-v2 fold-in (amends §3.2, §3.3, §4, §5, §6, §7, §13)

The v2 golden (`prototypes/zest-redesignv2.html`) adds the following. Each is small and
maps onto the existing architecture; new FFI is already in §3.2.

**A. Editable breadcrumb (the #1 daily-use win).** `Shell/Breadcrumb` is a custom NSView
that renders styled path tokens — home `~` (accent), parent dirs dim, **current segment
emphasized**, each segment **tinted by its directory's folder color** (`zest_folder_color`),
`/Volumes/…` distinct — and on click swaps to an `NSTextField` pre-filled with the
absolute path, fully selected: **paste + ⏎ navigates** (parse `~`/`~/`/abs/rel exactly
like the engine's `resolveEnteredPath`), Esc reverts. Replaces today's plain path field.

**B. Scope-aware Categories tree (NEW engine work).** `Sidebar/CategoryTree`: expandable
category rows (dot + name + count) that expand to their **extensions** with counts,
computed over the **current scope** (this folder vs recursive). Backed by the new
`zest_histogram(scope_root, max_depth)` — reuses category bitmaps; extension tallies
lazily on expand, off-main (§13.8). Click category → `cat:` token; extension → `ext:`
token (toggle), mirrored into the search field + chips.

**C. Saved-filters manager.** A real window/sheet (`SavedFiltersWindow`, or a SwiftUI
island) — bookmark-manager CRUD over `FilterStore` via `zest_filters_*`. Opened from the
toolbar `Saved ▾` popover → "Manage…". The prototype's reusable **overlay/dialog** = an
AppKit sheet (`beginSheet`) or child window; factor a `Shell/Dialog` host.

**D. Status indexed-count.** Space thousand-separators (`1 240 118`); click-to-copy to
`NSPasteboard` with a brief flash (no toast).

**E. Columns + Modified format.** Per §7 (amended): 5 columns; Modified = ISO date + dim
relative time, baseline-aligned.

**F. Theming.** Per §4.2 / §4.5 (amended): dark + light via token flip; one accent base,
theme-shifted darker on light; OKLCH-style perceptual derivation.

**G. Global polish.** Consistent keyboard focus ring (`accentLine`) on every control;
smooth expand animation when a list row opens into an inline edit form (no jarring jump);
body text antialiasing.

**New Swift components (added to §3.3):** `Shell/Breadcrumb`, `Shell/Dialog`,
`Sidebar/CategoryTree`, `SavedFiltersWindow` (or SwiftUI island), `Design/ThemeManager`.

**Build-order placement:** breadcrumb + columns + count → P2/P3; category histogram +
saved-filters window → P4; theming starts at P0 (tokens), refined through P4.
