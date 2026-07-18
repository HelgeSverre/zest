# Space-to-preview + syntax highlighting, Finder actions, column stretch, .sema category

**Date:** 2026-07-18
**Status:** Approved for implementation

## Goal

Press Space on a selected row to preview it, matching Finder's QuickLook
muscle memory:
- For `.md`, `.sema`, `.json` specifically: a custom in-app overlay showing
  the file's contents with real syntax highlighting.
- For everything else: hand off to the system's registered QuickLook
  generator for that file type (whatever Finder would show).

Plus three small, independent polish items bundled into the same
implementation pass: an "Open in Finder" context-menu action, result columns
that stretch to fill the window on resize, and `.sema` categorized as Code.

## Highlighting engine: tree-sitter

One engine for all three highlighted formats, not three different
techniques. `tree-sitter` was chosen over `HighlighterSwift` (a highlight.js
wrapper) because HighlighterSwift's public API has **no hook to register a
custom language grammar** — its `JSContext`/`hljs` object is private with no
extension point — which is a hard blocker for `.sema`, a language that
doesn't exist in highlight.js's bundled language set.

`~/code/sema/tree-sitter-sema` (public: `github.com/sema-lisp/tree-sitter-sema`)
already ships a canonical `queries/highlights.scm` using the standard
tree-sitter capture-name convention (`@keyword`, `@string`, `@comment`,
`@function.builtin`, `@variable.parameter`, `@punctuation.bracket`, …) — the
same convention Neovim/Helix/Zed use. This is read directly, not
hand-transcribed, so highlighting is exactly as correct as your editor's.

| Format | Grammar source |
|---|---|
| `.json` | `github.com/tree-sitter/tree-sitter-json` — public SPM package, remote dependency |
| `.md` / `.markdown` | `github.com/tree-sitter-grammars/tree-sitter-markdown` — public SPM package; ships two C targets (`TreeSitterMarkdown` block grammar + `TreeSitterMarkdownInline`), both needed |
| `.sema` | Vendored locally first (see below), upstreamed later |

### `.sema` grammar sourcing

`tree-sitter-sema` is public but has no `Package.swift`/Swift bindings yet
(only `c`/`node`/`rust` are declared in its `tree-sitter.json`) — so it isn't
resolvable as a remote SPM dependency as-is.

**Phase 1 (this implementation):** vendor a snapshot of the already-generated
`src/parser.c`, `src/scanner.c`, `src/tree_sitter/*.h`, and
`queries/highlights.scm` into a local `Vendor/TreeSitterSema/` Swift package
target inside zig-finder, structured to match the standard SPM
tree-sitter-grammar shape (`bindings/swift/tree_sitter_sema.h` forward-
declaring `const TSLanguage *tree_sitter_sema(void)`, `publicHeadersPath`
pointing there, `sources: ["src/parser.c", "src/scanner.c"]`,
`cSettings: [.headerSearchPath("src")]`). A header comment records the source
commit (`be9019c`, 2026-07-10) so it can be diffed against upstream later.

**Phase 2 (follow-up, out of scope here):** once this proves out, file an
issue/PR against `sema-lisp/tree-sitter-sema` adding `bindings/swift/` +
`Package.swift` (mirroring its existing c/node/rust bindings), then switch
Zest to a normal remote dependency and delete the vendored copy.

### Package.swift additions

```swift
dependencies: [
    .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.10.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-json", from: "0.24.0"),
    .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", branch: "split_parser"),
],
targets: [
    .target(name: "CZestCore"),
    .target(
        name: "TreeSitterSema",
        path: "Vendor/TreeSitterSema",
        sources: ["src/parser.c", "src/scanner.c"],
        resources: [.copy("queries")],
        publicHeadersPath: "bindings/swift",
        cSettings: [.headerSearchPath("src")]
    ),
    .executableTarget(
        name: "Zest",
        dependencies: [
            "CZestCore", "TreeSitterSema",
            .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
            .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
            .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
            .product(name: "TreeSitterMarkdownInline", package: "tree-sitter-markdown"),
        ],
        linkerSettings: [ /* existing libzest-core flags unchanged */ ]
    ),
    // ZestTests unchanged
]
```

This is a real increase in dependency weight for a project that's been
deliberately dependency-free (three external SPM packages plus their
transitive pull of `tree-sitter/tree-sitter`'s C runtime, plus one vendored
local C target). Noted, not re-litigated — this was the explicit redirect
away from HighlighterSwift.

### `TreeSitterHighlighter` (new, `Sources/Zest/Preview/`)

One small wrapper, not per-language special-casing:

1. `Parser().setLanguage(language)`, `parser.parse(source)` → `Tree`.
2. Run the grammar's `Query(.highlights)` against the tree, resolve capture
   ranges + names via `cursor.resolve(with: .init(string: source)).highlights()`.
3. Map each capture name to an `NSColor` via one `[String: NSColor]` table
   (new `Theme.syntax*` constants — keyword/string/comment/number/constant/
   function/punctuation, ~7 additions reusing existing Ink-palette hues).
   **Unmapped capture names fall back to `Theme.text`** (no color) rather than
   erroring — a grammar producing a capture name outside the expected set
   (e.g. a markdown-specific capture) degrades gracefully instead of crashing
   or looking broken.
4. Build one `NSAttributedString` (monospaced font, base `Theme.text`,
   colored runs applied on top per capture).

Runs off-main (a background serial queue, matching `AppCoordinator`'s
off-main query convention) since JS-free tree-sitter parsing is still
uncached, unbounded work relative to file size; the resulting
`NSAttributedString` is delivered back to main.

`Parser`/`Tree`/`Query`/`QueryCursor` instances are not thread-safe to share
across threads — each preview build creates its own, used start-to-finish
on the one background queue call, then discarded. `Language` (immutable,
wraps a const grammar pointer) is safe to hold as a static per-grammar
constant.

## Preview overlay + QuickLook

- **Space** on a selected browser row: extension (lowercased) ∈
  `{md, markdown, sema, json}` → the custom overlay; anything else → the
  system `QLPreviewPanel` for that file's registered handler. Space again
  toggles whichever one is open closed — this applies to both paths, not
  just the custom overlay (QLPreviewPanel gets this for free from AppKit
  once wired via the standard protocol; the custom overlay implements the
  same toggle explicitly).
- New `FilePreviewOverlay` (`Sources/Zest/Shell/`, following the
  `SavedFiltersDialog` scrim + centered panel pattern already in the app):
  filename header + close button, a scrollable read-only monospaced
  `NSTextView` body showing the highlighter's `NSAttributedString`. Esc or
  scrim-click closes. Mounted once by `RootViewController`, hidden until
  shown — same lifecycle as the saved-filters overlays.
- Files over **5 MB** skip highlighting and show plain unhighlighted text
  (still previewable, just not colored) — avoids an unbounded parse on a
  huge file blocking the preview.
- Arrowing to a different row while either the overlay or the QL panel is
  open live-updates the preview, matching Finder.
- `ZestTableView.keyDown` gains keyCode 49 (Space) → a new
  `onPreviewSelection` callback (same wiring shape as the existing
  `onActivateSelection`/`menuForRow` callbacks), routed by
  `BrowserViewController` to either the overlay or `QLPreviewPanel`.
- QuickLook wiring is standard AppKit boilerplate: `BrowserViewController`
  conforms to `QLPreviewPanelDataSource`/`QLPreviewPanelDelegate`, overrides
  `acceptsPreviewPanelControl`/`beginPreviewPanelControl(_:)`/
  `endPreviewPanelControl(_:)`; a small `QLPreviewItem`-conforming wrapper
  exposes the selected file's `URL`.

## Small polish items (same implementation pass, no separate spec)

### "Open in Finder"

Next to the existing "Reveal in Finder" (`BrowserViewController.swift:352`):
for a **file**, opens its *containing folder* as a new Finder window (not
selecting the file — just the folder); for a **folder**, opens *that
folder's contents*. Reuses the exact `item.isDirectory ? item.path :
item.dirPath` pattern already used one item below by "Open in Terminal",
via `NSWorkspace.shared.open(URL(fileURLWithPath: target))`.

### Column stretch-to-fit

`buildTable()`: `columnAutoresizingStyle` changes from
`.lastColumnOnlyAutoresizingStyle` to `.uniformColumnAutoresizingStyle`.
Today SIZE/MODIFIED/KIND/EXT all have `minWidth == maxWidth`, so they're
mathematically incapable of absorbing resize slack; with the uniform style,
100% of any resize delta falls through to NAME (the only column with real
range: min 240 / max 100,000) — exactly the "stretch to fit" behavior
wanted, with no other column config changes needed.

### `.sema` → Code category

One line in `src/core/file_types.zig`'s `extension_map`:
`.{ "sema", .code },`. Categorization is baked into the index at build time
(same mechanism as the recursive-folder-size feature), so this needs
`format.VERSION` bumped 4→5 to force a reindex — otherwise `.sema` files in
an already-built index keep showing stale (uncategorized) category bytes.

## Testing

- Zig: extend `file_types.zig`'s existing categorize() tests with a `.sema`
  → `.code` case.
- Swift: `TreeSitterHighlighter` capture-name → color mapping is a pure
  function, testable without a real parse — feed synthetic
  `(captureName, NSRange)` pairs, assert the resulting attributed string's
  colors at those ranges. A small real-parse smoke test per grammar (parse a
  short literal snippet of each language, assert it doesn't crash and
  produces a non-empty attributed string) covers the C-target wiring itself.
- Swift: extension-routing logic (`{md, markdown, sema, json}` → overlay vs
  QuickLook) as a pure static function, table-driven, matching the house
  pattern (`SearchField.refreshDecision`, `Breadcrumb.segmentsToCollapse`).
- Manual (no UI automation on host, per project memory): Space on a `.sema`/
  `.md`/`.json` file shows the highlighted overlay with sensible colors;
  Space on e.g. a `.pdf`/`.png` shows the system QuickLook panel; Space
  again closes either; arrowing through rows live-updates the open preview;
  "Open in Finder" opens the right folder for both a file and a directory;
  resizing the window wider visibly grows the NAME column while
  SIZE/MODIFIED/KIND/EXT stay fixed; a freshly reindexed `.sema` file shows
  under the Code category in the sidebar.

## Out of scope

- Upstreaming Swift bindings to `tree-sitter-sema` (phase 2, follow-up once
  the vendored copy proves out).
- Editing inside the preview overlay (read-only, matches QuickLook's own
  read-only preview).
- Incremental/keystroke-level re-highlighting (not needed — this is a
  one-shot "parse the whole file once" preview, not an editor).
- Syntax highlighting for any format beyond `.md`/`.sema`/`.json`.
