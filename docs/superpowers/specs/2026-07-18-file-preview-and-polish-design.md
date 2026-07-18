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
    .package(url: "https://github.com/tree-sitter/swift-tree-sitter", exact: "0.25.0"),
    .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
    .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", exact: "0.5.3"),
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
        ],
        linkerSettings: [ /* existing libzest-core flags unchanged */ ]
    ),
    // ZestTests keeps depending on Zest; grammar products are visible transitively.
]
```

`TreeSitterMarkdown` is the package's only library product. It contains both
the `TreeSitterMarkdown` and `TreeSitterMarkdownInline` targets, so Zest can
import both modules without naming a nonexistent second product. Exact versions
keep generated C parsers, query files, and the tree-sitter runtime reproducible.

This is a real increase in dependency weight for a project that's been
deliberately dependency-free (three external SPM packages plus their
transitive pull of `tree-sitter/tree-sitter`'s C runtime, plus one vendored
local C target). Noted, not re-litigated — this was the explicit redirect
away from HighlighterSwift.

### Query resources (new, `Sources/Zest/Preview/QueryResourceLoader.swift`)

Zest loads `highlights.scm` itself instead of using
`LanguageConfiguration(name:)`. SwiftTreeSitter 0.25.0 assumes an Xcode-style
`Contents/Resources` layout on macOS, while `swift run` produces flat SwiftPM
resource bundles. The loader checks both layouts beneath the executable,
`Bundle.main`, loaded test bundles, and each bundle's parent directory. The
exact resource bundle names are:

- `TreeSitterJSON_TreeSitterJSON.bundle`
- `TreeSitterMarkdown_TreeSitterMarkdown.bundle`
- `TreeSitterMarkdown_TreeSitterMarkdownInline.bundle`
- `Zest_TreeSitterSema.bundle`

The loader returns the direct URL of `queries/highlights.scm` and constructs
`Query(language:url:)`. Failure is a preview error shown in the overlay, not a
crash or a silent all-plain result. The same lookup must pass under both
`swift run` and `swift test`.

### `TreeSitterHighlighter` (new, `Sources/Zest/Preview/`)

The public wrapper exposes one `highlight(source:format:)` entry point, with
format-specific parser configuration hidden behind it:

1. JSON and Sema each use one `Parser`, one tree, and one highlights query.
2. Markdown first parses the block grammar. It walks the block tree for every
   `inline` and `pipe_table_cell` node, converts those nodes to included ranges,
   and excludes named child ranges exactly as the grammar's upstream parser
   requires. A second parser parses those ranges with
   `TreeSitterMarkdownInline`. Both highlight queries run; block captures are
   applied first and inline captures second so the more specific inline styles
   win.
3. Each query executes against its tree and resolves predicates with
   `cursor.resolve(with: .init(string: source)).highlights()`.
4. Capture names use hierarchical style resolution: exact name first, then
   parent components. For example, `function.builtin` inherits `function`,
   `string.special.key` inherits `string`, and `punctuation.bracket` inherits
   `punctuation`. Markdown's `text.title`, `text.literal`, `text.uri`,
   `text.reference`, `text.emphasis`, and `text.strong`, plus Sema's `operator`
   and `variable`, receive explicit styles. `none` resets to the base style;
   truly unmapped names fall back to `Theme.text`.
5. Build one `NSAttributedString` with a monospaced base font and
   `Theme.text`, applying colored runs in query order.

Parsing runs off-main on a background serial queue. Every request carries a
monotonically increasing generation. Main-thread delivery is ignored unless
its generation is still current, preventing a slow prior selection from
overwriting a newer preview or reopening a closed overlay.

`Parser`/`Tree`/`Query`/`QueryCursor` instances are not thread-safe to share
across threads — each preview build creates its own, used start-to-finish
on the one background queue call, then discarded. `Language` (immutable,
wraps a const grammar pointer) is safe to hold as a static per-grammar
constant.

## Preview overlay + QuickLook

- `BrowserViewController` is the single preview-state owner with
  `closed`, `custom(URL, PreviewFormat)`, and `quickLook(URL)` states. `RootViewController`
  only mounts `FilePreviewOverlay` and injects that view into the browser.
- **Space** on a selected browser row: extension (lowercased) ∈
  `{md, markdown, sema, json}` on a regular file → the custom overlay;
  directories and everything else → the system `QLPreviewPanel`. Space again
  explicitly orders out whichever preview is open.
- New `FilePreviewOverlay` (`Sources/Zest/Shell/`, following the
  `SavedFiltersDialog` scrim + centered panel pattern already in the app):
  filename header + close button, a scrollable read-only monospaced
  `NSTextView` body showing the highlighter's `NSAttributedString`. It does not
  steal first responder from the table when shown, so Up/Down continue to move
  the selection. Esc or
  scrim-click closes. Mounted once by `RootViewController`, hidden until
  shown — same lifecycle as the saved-filters overlays.
- Files up to **5 MiB** are highlighted. Larger custom-format files show plain
  text. Custom previews read at most **20 MiB**; larger files show the decoded
  prefix followed by a truncation notice. `String(decoding:as: UTF8.self)`
  replaces malformed byte sequences instead of failing the whole preview.
  Missing, unreadable, or vanished files show an inline error state.
- Arrowing to a different row while either the overlay or the QL panel is
  open live-updates the preview, matching Finder. Crossing format boundaries
  closes the current surface before opening the other one.
- `ZestTableView.keyDown` gains keyCode 49 (Space) → a new
  `onPreviewSelection` callback (same wiring shape as the existing
  `onActivateSelection`/`menuForRow` callbacks), routed by
  `BrowserViewController` to either the overlay or `QLPreviewPanel`.
- QuickLook wiring imports `QuickLookUI`; `BrowserViewController`
  conforms to `QLPreviewPanelDataSource`/`QLPreviewPanelDelegate`, overrides
  `acceptsPreviewPanelControl`/`beginPreviewPanelControl(_:)`/
  `endPreviewPanelControl(_:)`, and returns the selected `NSURL` directly as
  the one preview item. Selection changes call `reloadData()` and reset
  `currentPreviewItemIndex` to zero. A close notification returns preview state
  to `closed` when the panel's own close button is used.

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
`format.VERSION` is bumped 4→5 so the reader rejects an index containing stale
category bytes. Rejection does not itself rebuild the file: upgrading requires
restarting the newly built daemon (which starts with a full scan) or running
`just index` manually. Until then the app shows its existing no-index state.

## Testing

- Zig: extend `file_types.zig`'s existing categorize() tests with a `.sema`
  → `.code` case.
- Swift: test hierarchical capture-style mapping with synthetic capture names.
  Real-parse tests assert representative non-base colors for JSON keys/numbers,
  Sema keywords/builtins, Markdown block headings, and Markdown inline emphasis
  or links. These tests cover C-target wiring, query-resource discovery, and
  the split Markdown pipeline; an all-plain attributed string must fail them.
- Swift: extension-routing logic (`{md, markdown, sema, json}` → overlay vs
  QuickLook, with directories always QuickLook) is a pure static function,
  table-driven, matching the house pattern (`SearchField.refreshDecision`,
  `Breadcrumb.segmentsToCollapse`). Test preview-state transitions separately.
- Swift: test the 5 MiB highlight boundary, 20 MiB read truncation marker,
  invalid UTF-8 replacement, and stale-generation rejection without AppKit UI
  automation.
- Swift integration tests that inspect the optional developer-local index skip
  with a `just index` migration instruction when the v5 reader rejects a
  present v4 index; tests must not silently rebuild or overwrite user data.
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

## Performance correction: embedded highlight queries

Profiling after the first implementation found that preview startup was dominated
by `QueryResourceLoader`, not parsing or file I/O. The loader enumerated every
loaded bundle/framework and repeatedly compared standardized URL paths before
reading four known, version-pinned `highlights.scm` files. On the profiled build,
that discovery took roughly 424–496 ms per preview while the actual query read,
parse, and execution work was measured in milliseconds.

Highlight queries are therefore build inputs, not runtime resources:

- Check in exact snapshots of the JSON and Markdown queries from the versions in
  `Package.resolved`; continue using the already-vendored Sema query snapshot.
- A SwiftPM build-tool plugin declares all four query files as inputs and emits a
  deterministic Swift source file containing their bytes. SwiftPM compiles that
  generated source into `Zest`, so installed and test binaries need no query-file
  path discovery.
- `TreeSitterHighlighter` constructs one immutable `Query` for each grammar/query
  pair (JSON, Sema, Markdown block, Markdown inline) and reuses it. Every parse
  still gets its own parser and query cursor; those stateful objects are not
  shared.
- Query initialization failures remain thrown errors. Cached initialization uses
  `Result<Query, Error>` rather than crashing through `try!`.
- Remove `QueryResourceLoader` and the Sema query resource declaration. External
  grammar packages may still bring their own resource bundles, but Zest neither
  searches nor reads those bundles at runtime.

Tests assert that the generated sources contain representative captures, that
each query kind returns the same cached `Query` identity across calls, and that
the existing real JSON/Sema/Markdown highlighting behavior is unchanged. A
post-change release benchmark must separately report first and warm preview
latency so build/plugin time is not mistaken for runtime work.

The release benchmark on the implementation branch measured:

| Format | First highlight | Warm average |
| --- | ---: | ---: |
| JSON | 4.379 ms | 0.018 ms |
| Sema | 1.382 ms | 0.036 ms |
| Markdown | 2.677 ms | 0.065 ms |

Each warm value is the mean of 200 highlights in the same process. The first
value includes that format's one-time `TSQuery` construction.
