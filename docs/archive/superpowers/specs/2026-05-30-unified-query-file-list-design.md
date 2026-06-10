# Unified Query File List — Design

**Date:** 2026-05-30
**Status:** Approved for planning
**Component:** Zest GUI (file list, search/index, config)

## Problem

The file list has two divergent data paths branched on `is_search_mode`
everywhere: *browse* renders `FileEntry` from a live filesystem `DirListing`,
*search* renders `SearchResult` from the global mmap index. Every table callback
(`numberOfRows`, `objectValueForTableColumn`, `viewForTableColumn`,
`getPathForRow`) duplicates this branch.

This divergence is the root friction behind five requested changes — each would
otherwise have to be built twice:

1. Filtering should be scoped to the current folder's subtree by default.
2. The Name column should optionally show the file's path, not just the basename.
3. Columns are not sortable.
4. Double-clicking a column header "passes through" and opens the row beneath it.
5. "Open in Terminal" hardcodes Terminal.app; it should respect a user preference.

## Core Idea

Collapse the two paths into **one**: the file list is *always* the result of a
single query against the index. There is no listing-vs-search mode — only a
`Query`. A folder listing is a query with an empty text and depth 1. A global
search is a query scoped to `/`. The UI manages only "chrome" (the scope/path
field and the search field); it never branches on semantics.

```
Query = {
    scope: []const u8,   // absolute folder path; "/" = everything indexed
    text:  []const u8,   // name filter; "" = match all
    max_depth: u32,      // 1 = direct children (a listing); maxInt = recursive
}
```

| User action                         | Query                                  |
|-------------------------------------|----------------------------------------|
| List `~/code`                       | `query("~/code", "", 1)`               |
| Filter "reader" under `~/code`      | `query("~/code", "reader", maxInt)`    |
| Global filter "reader"              | `query("/", "reader", maxInt)`         |

The controller that builds a `Query` sets `max_depth = if (text.len == 0) 1 else maxInt`
in **one place**. The UI does not decide this.

### Data backend

Everything — listing and filtering — comes from the mmap index (the single
engine). Accepted trade-offs:

- Browsing only works where the index reaches (the daemon watches `~$HOME`);
  un-indexed areas show an empty list.
- Results reflect index freshness, not the live filesystem: new/renamed files
  lag until the daemon reindexes (~30s or 1000 FS events). The app already polls
  for a fresh index every ~5s and reloads it.
- No external/mounted-volume support (not supported today; out of scope).

The live-filesystem `FileSystemProvider`/`RealFs`/`FakeFs` abstraction stays
(used by `main`'s initial `isDir` check and by tests) but no longer backs the
file list.

## Architecture

### 1. Engine: scope + depth predicate (`index/search.zig`)

Extend `SearchOptions`:

```zig
pub const SearchOptions = struct {
    query: []const u8,
    category: ?types.FileCategory = null,
    filters: []const filters_mod.FilterCriterion = &.{},
    scope: []const u8 = "/",      // NEW: absolute folder path
    max_depth: u32 = std.math.maxInt(u32), // NEW
};
```

Apply a scope predicate to each candidate entry, using `reader.getDirPath(idx)`:

- Normalize `scope` (treat `"/"` as matching everything).
- `max_depth == 1`: entry matches iff `dir_path == scope` (direct children only).
- `max_depth > 1`: entry matches iff `dir_path == scope` **or** `dir_path`
  begins with `scope ++ "/"` (segment-boundary prefix, so `/a/b` matches
  `/a/b/c` but **not** `/a/bc`). If a finite depth between 1 and ∞ is ever
  needed, count path separators beyond `scope`; only 1 and maxInt are used now.

**Critical change:** the current early return
`if (!has_text and !has_filters) return empty;` (search.zig:44) must no longer
short-circuit when a scope is active. The scope is a real predicate: an
empty-text, depth-1 query must return the scoped folder's direct children. Treat
"has a non-root scope or finite depth" as sufficient reason to scan and emit.

Directories are present in the index (the indexer emits an entry per directory
with `dir_path` = its parent), so depth-1 listings include subfolders as folder
rows, and navigating into one sets `scope` to that folder's full path.

`searchCancellable` keeps its generation-based cancellation; the scope/depth
check is added inside the existing scan loop.

### 2. Engine plumbing (`app.zig`, `core/async_search.zig`)

- `App.search` and `AsyncSearch.submitSearch` gain `scope` and `max_depth`
  parameters, threaded into `SearchOptions`.
- **Result type stays `[]SearchResult`** (`{ name, dir_path, size, mtime, kind,
  category }`). It becomes *the* row type for the entire file list.
- Existing async generation/cancellation and main-thread (GCD) result delivery
  are reused unchanged.

### 3. UI: single row path (`ui/delegate.zig`, `ui/file_list.zig`)

- Remove the `is_search_mode` split. `current_entries` / `DirListing` /
  `FileEntry` no longer feed the table.
- `AppState` holds a single owned `rows: []search_mod.SearchResult` and the
  current `scope` (which is `Navigator.current`).
- Every table callback reads `rows` — one code path, no branching:
  - `numberOfRows` → `rows.len`
  - `viewForTableColumn` / `objectValue` → `rows[i]` fields
  - `getPathForRow` → `rows[i].dir_path ++ "/" ++ rows[i].name`
- `Navigator.current` **is** the scope. Double-clicking a folder, Back, Forward,
  and Up change the scope, clear `text`, and re-run the query. Editing the search
  field changes `text` and re-runs the query (debounced, async — unchanged).
- One owned `rows` slice is freed/replaced atomically per query result delivery,
  replacing the dual ownership of `DirListing` + `search_results`.

### 4. Feature: folder-scoped recursive filter

Falls out of the model. Non-empty `text` runs `query(scope, text, maxInt)`. No
`path:` substring hack; the scope predicate is the real prefix match. A
user-typed explicit `path:` filter still applies as an additional criterion.

### 5. Feature: sortable columns

- In `createFileList`, mark all four columns sortable: set a
  `sortDescriptorPrototype` (key = column identifier) on each `NSTableColumn`.
- Register `tableView:sortDescriptorsDidChange:` on the data source. It reads the
  active descriptor `{ key, ascending }`, stores it on `AppState`
  (`sort: ?{ column: enum, ascending: bool }`), sorts `rows` in place via one
  comparator over `SearchResult`, and calls `reloadData`.
- **Pure column sort, no folder grouping** (a 0-byte folder sorts among 0-byte
  files). Comparator keys: name (case-insensitive), size (u64), mtime (i64),
  type (category name). Clicking a header toggles ascending/descending.
- Default order when no descriptor is set: Name ascending.
- The comparator must also be applied to freshly delivered query results so sort
  order persists across navigation and filtering.

### 6. Feature: Show Full Path toggle

- `AppState.show_full_path: bool` (persists for the session; default off).
- One display function `displayName(row, scope, show_full_path) -> []const u8`:
  - **off** → path relative to `scope`: `dir_path` with the `scope` prefix
    stripped, joined with `name`. For a direct child this is just `name`; for a
    nested match it is e.g. `index/reader.zig`.
  - **on** → absolute path: `dir_path ++ "/" ++ name`.
- The Name cell builder calls `displayName` instead of using the bare basename.
- Exposed as a checkable **View ▸ Show Full Path** menu item with key equivalent
  **⌘⇧P**. Toggling flips the bool, updates the item's check state, and
  `reloadData`.
- **Dependency:** there is currently no main menu bar (only right-click context
  menus). This spec includes adding a minimal `NSMenu` main menu via
  `NSApplication setMainMenu:` — at least an application menu (so ⌘Q etc. behave)
  and a View menu hosting this item. The ⌘⇧P key equivalent is the menu item's
  key equivalent.

### 7. Feature: header double-click fix

In the open handler (`openItemAction` → `contextPathFromSenderOrSelection` →
`preferredTableIndex`/`clickedTableIndex`), reject the hit when the click landed
in the header: convert the table's current event location to table coordinates
and call `rowAtPoint:`; if it returns `< 0` (header or empty area), do not open.
This ensures header clicks only sort and never open the row beneath. (Sorting
itself is driven by the standard header-click → `sortDescriptorsDidChange:`
path, independent of the double-action.)

### 8. Feature: smart Open in Terminal (`app.zig`, `config/config.zig`)

- Add a `terminal` string key to `config.json` (read from
  `~/.config/zest/config.json`).
- `App.openInTerminal(path)` builds an ordered candidate list:
  `[config.terminal (if set)] ++ ["iTerm", "Ghostty", "WezTerm", "kitty", "Alacritty", "Terminal"]`
  (de-duplicated). It runs `open -a <name> <folder>` for each candidate **in
  order**, waiting on the exit code, and stops at the first that exits 0. A
  missing app makes `open` exit non-zero **without launching anything**, so no
  spurious window opens; Terminal.app (always present, last in the list) is the
  guaranteed fallback.
- This requires waiting on the child's exit status (we already use
  `std.process.spawn(io, ...)` + `child.wait(io)`), not fire-and-forget.
- **Dependency:** `config.zig` currently has only path helpers and no JSON
  loader. Add a minimal config reader that parses the `terminal` key (follow the
  existing JSON read pattern in `core/pins.zig` / `core/folder_colors.zig`). When
  config or the key is absent, `terminal` is null and auto-detection applies.

## Memory & Lifetime

- A single owned `rows: []SearchResult` and its backing allocations replace
  `current_entries` (`DirListing`) and `search_results`. The previous result is
  freed when a new one is installed on the main thread, reusing the async
  generation guard so stale deliveries are dropped, not leaked.
- Sorting reorders `rows` in place (no reallocation).

## Error & Edge Handling

- **No index loaded:** the file list is empty; show a status hint
  ("No index — run `zest-indexer`") rather than erroring.
- **Empty scope result:** an indexed-but-empty or un-indexed folder shows an
  empty list (expected per the index-only trade-off).
- **`scope == "/"`:** matches all indexed entries; relative-path display equals
  the absolute path minus the leading `/`.
- **Open in Terminal, no candidate succeeds:** cannot happen in practice
  (Terminal.app is always installed); if it somehow does, surface no window and
  log a warning.

## Testing (FakeFs-built index; no real FS, no UI)

- **Scope/depth predicate:** depth-1 returns exact-dir children including
  subdirs; recursive returns the full subtree; segment-boundary prefix
  (`/a/b` excludes `/a/bc`); `scope == "/"`; empty `text` vs non-empty `text`.
- **Empty-query listing:** `query(scope, "", 1)` returns the folder's direct
  children (regression guard for the removed early-return short-circuit).
- **Comparator:** name/size/mtime/type each ascending and descending.
- **Display:** `displayName` for off/on × direct-child/nested × `scope == "/"`.
- **Terminal selection (pure logic):** candidate-list construction —
  config value first, de-duplicated, Terminal.app last. (Actual `open`
  invocation is not unit-tested.)

## Out of Scope

- External/mounted volumes; live-filesystem listing for the main list.
- A dir→children index for O(1) listings (future optimization; current O(n)
  scan is acceptable at present scale, p50 ≈ 13 ms, async + debounced).
- "Show Hidden Files" and other View-menu items beyond Show Full Path.
- Finite sort grouping (folders-first) — explicitly chose pure column sort.
