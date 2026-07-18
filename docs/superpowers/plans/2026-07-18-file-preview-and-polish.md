# File Preview and Finder Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Finder-style Space preview with custom tree-sitter highlighting for Markdown, Sema, and JSON, plus the approved Finder action, table resizing, and Sema categorization polish.

**Architecture:** `BrowserViewController` owns one preview state and switches between a root-mounted `FilePreviewOverlay` and the system `QLPreviewPanel`. `PreviewContentLoader` performs bounded file reads and generation-checked background highlighting; `TreeSitterHighlighter` owns grammar parsing while `QueryResourceLoader` locates the pinned grammar query bundles in executable and XCTest layouts.

**Tech Stack:** Swift 5.9/AppKit/QuickLookUI, SwiftTreeSitter 0.25.0, tree-sitter-json 0.24.8, tree-sitter-markdown 0.5.3, vendored tree-sitter-sema commit `be9019c`, Zig 0.16.0.

## Global Constraints

- macOS deployment target remains 14.
- Custom highlighting applies only to regular `.md`, `.markdown`, `.sema`, and `.json` files.
- Highlight at most 5 MiB and read at most 20 MiB for a custom preview.
- The table remains first responder when the custom overlay opens.
- Every asynchronous result is guarded by a generation token.
- Existing `libzest-core.a` linker settings remain unchanged and ReleaseFast is restored after Zig tests.
- Do not modify or stage the unrelated `reddit-scrutiny.json` file.

---

### Task 1: Pin grammar dependencies and vendor Sema

**Files:**
- Modify: `Package.swift`
- Create: `Vendor/TreeSitterSema/bindings/swift/tree_sitter_sema.h`
- Create: `Vendor/TreeSitterSema/src/parser.c`
- Create: `Vendor/TreeSitterSema/src/scanner.c`
- Create: `Vendor/TreeSitterSema/src/tree_sitter/alloc.h`
- Create: `Vendor/TreeSitterSema/src/tree_sitter/array.h`
- Create: `Vendor/TreeSitterSema/src/tree_sitter/parser.h`
- Create: `Vendor/TreeSitterSema/queries/highlights.scm`

**Interfaces:**
- Produces the importable C module `TreeSitterSema` and function `tree_sitter_sema()`.
- Makes `SwiftTreeSitter`, `TreeSitterJSON`, `TreeSitterMarkdown`, `TreeSitterMarkdownInline`, and `TreeSitterSema` visible to target `Zest`.

- [x] Copy the exact generated grammar snapshot from `/Users/helge/code/sema/tree-sitter-sema` at commit `be9019c` and add this public header:

```c
#ifndef TREE_SITTER_SEMA_H_
#define TREE_SITTER_SEMA_H_
typedef struct TSLanguage TSLanguage;
#ifdef __cplusplus
extern "C" {
#endif
const TSLanguage *tree_sitter_sema(void);
#ifdef __cplusplus
}
#endif
#endif
```

- [x] Add exact SwiftPM dependency versions and the local target. Depend only on the `TreeSitterMarkdown` product because it contains both Markdown modules.
- [x] Run `swift package resolve && swift build`; expect dependency resolution at `0.25.0`, `0.24.8`, and `0.5.3`, followed by `Build complete!`.

### Task 2: Build the query loader and highlighter test-first

**Files:**
- Create: `Sources/Zest/Preview/PreviewFormat.swift`
- Create: `Sources/Zest/Preview/QueryResourceLoader.swift`
- Create: `Sources/Zest/Preview/TreeSitterHighlighter.swift`
- Modify: `Sources/Zest/Design/Theme.swift`
- Create: `Sources/ZestTests/TreeSitterHighlighterTests.swift`

**Interfaces:**
- `enum PreviewFormat { case markdown, sema, json }`
- `static func customFormat(for url: URL, isDirectory: Bool) -> PreviewFormat?`
- `QueryResourceLoader.highlightsURL(bundleName: String) throws -> URL`
- `TreeSitterHighlighter.highlight(source: String, format: PreviewFormat) throws -> NSAttributedString`
- `TreeSitterHighlighter.color(forCaptureName: String) -> NSColor`

- [x] Write routing, hierarchical capture-color, resource-discovery, and representative JSON/Sema/Markdown real-parse tests. Markdown must assert both heading and inline-link/emphasis styling.
- [x] Run `swift test --filter TreeSitterHighlighterTests`; expect compilation failure because the production types do not exist.
- [x] Implement exact/parent capture matching, query execution, and the two-pass Markdown included-range parse.
- [x] Run `swift test --filter TreeSitterHighlighterTests`; expect all highlighter tests to pass.

### Task 3: Build bounded preview content loading test-first

**Files:**
- Create: `Sources/Zest/Preview/PreviewContentLoader.swift`
- Create: `Sources/ZestTests/PreviewContentLoaderTests.swift`

**Interfaces:**
- `PreviewContentLoader.ContentResult` contains `attributedString`, `wasHighlighted`, and `wasTruncated`.
- `load(url:format:completion:)` increments an internal generation, performs work on a private serial queue, and returns on main only when still current.
- `invalidate()` increments the generation so queued deliveries become stale.

- [x] Write tests for the 5 MiB boundary, 20 MiB truncation marker, malformed UTF-8 replacement, unreadable-file errors, and generation acceptance as a pure helper.
- [x] Run `swift test --filter PreviewContentLoaderTests`; expect failure because `PreviewContentLoader` does not exist.
- [x] Implement bounded `FileHandle.read(upToCount:)`, plain attributed output above 5 MiB, highlighting at or below the threshold, and stale-delivery rejection.
- [x] Run `swift test --filter PreviewContentLoaderTests`; expect all loader tests to pass.

### Task 4: Add overlay and coordinated preview state

**Files:**
- Create: `Sources/Zest/Shell/FilePreviewOverlay.swift`
- Modify: `Sources/Zest/Shell/RootViewController.swift`
- Modify: `Sources/Zest/Browser/BrowserViewController.swift`
- Create: `Sources/ZestTests/PreviewStateTests.swift`

**Interfaces:**
- `FilePreviewOverlay.show(url:format:)`, `showError(filename:message:)`, and `hide()`.
- `BrowserViewController.previewOverlay: FilePreviewOverlay?` is injected after both controllers are constructed.
- `PreviewState` has `.closed`, `.custom(URL, PreviewFormat)`, and `.quickLook(URL)`.
- `ZestTableView.onPreviewSelection` toggles preview for Space keyCode 49 and ignores repeats/modifier combinations.

- [x] Write pure routing/state-transition tests covering open, close, same-surface update, and cross-surface switch.
- [x] Run `swift test --filter PreviewStateTests`; expect failure because the reducer/state does not exist.
- [x] Implement the overlay without stealing first responder, mount it last in `RootViewController`, and wire Space plus selection-change live updates.
- [x] Import `QuickLookUI`; implement the one-item QL data source/delegate/controller methods, explicit panel toggling, reload on selection, and close-notification state reset.
- [x] Run `swift test --filter PreviewStateTests && swift build`; expect tests and compilation to pass.

### Task 5: Implement Finder/table/category polish test-first

**Files:**
- Modify: `Sources/Zest/Browser/BrowserViewController.swift`
- Modify: `Sources/ZestTests/ZestCoreTests.swift`
- Modify: `src/core/file_types.zig`
- Modify: `src/index/format.zig`

**Interfaces:**
- Context menu action `menuOpenFinder(_:)` receives the file's parent or the directory itself.
- `.sema` categorizes to `.code`; format version becomes 5.

- [x] Add `.sema` to the existing Zig categorization test before adding it to `extension_map`.
- [x] Run `zig build test`; expect the new assertion to fail.
- [x] Add the map entry and bump `VERSION` to 5; update the version comment to describe category semantics and manual reindex/restart requirements.
- [x] Treat a present but incompatible developer-local index like a missing optional integration fixture in Swift tests; skip it with the `just index` migration instruction instead of mutating user data during tests.
- [x] Add “Open in Finder” beside “Reveal in Finder” and switch table autoresizing to `.uniformColumnAutoresizingStyle`.
- [x] Run `zig build test && zig build core -Doptimize=ReleaseFast && swift test`; expect all tests to pass.

### Task 6: Format, verify, and self-review

**Files:**
- Review every file changed by Tasks 1–5.

- [x] Run `swift-format format --in-place --recursive Sources` and `zig fmt src`.
- [x] Run `just test`, `swift build`, and `swift-format lint --recursive Sources`; require exit code zero from each.
- [x] Inspect `git diff HEAD` for security, correctness, races, error handling, accidental unrelated changes, and resource/version drift.
- [x] Re-read `docs/superpowers/specs/2026-07-18-file-preview-and-polish-design.md` and check every requirement against implementation or an explicitly documented manual-only verification.
- [x] Leave the worktree with `zig-out/lib/libzest-core.a` rebuilt in ReleaseFast and report the required `just index` migration step.
